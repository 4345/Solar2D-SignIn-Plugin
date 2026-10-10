// ----------------------------------------------------------------------------
//
// PluginSignIn.mm — нативная часть plugin.signin для iOS: «Вход с Apple»
// (AuthenticationServices) и вход через Google (OAuth 2.0 с PKCE в системном
// окне ASWebAuthenticationSession — без SDK Google).
//
// Собирает её только проект Xcode (ios/Plugin.xcodeproj, минимальная версия
// iOS 15 — оба способа есть всегда). Android — на Java
// (android/plugin/src/main/java/plugin/signin/LuaLoader.java), Simulator и
// настольные приложения — Lua-заглушка (shared/plugin_signin.lua). Она же —
// основа таблицы и здесь: её байт-код (plugin_signin.c) строит таблицу
// библиотеки, а нативные функции ниже ставятся поверх.
//
// Lua API на iOS:
//   signin.version()                 -> "1.2.0"
//   signin.isAvailable()             -> { google = true, apple = true }
//   signin.apple(options, listener)  -> true | nil, сообщение
//       options.nonce (строка)      — попадёт в identity token как есть
//       options.email, options.fullName (логические) — запросить почту и имя
//           (Apple отдаёт их ТОЛЬКО при первом входе в приложение)
//   signin.google(options, listener) -> true | nil, сообщение
//       options.iosClientId (строка, обязательно) — iOS-клиент OAuth из
//           проекта Google Cloud (тот, что заведён на bundle ID приложения).
//           ID-токен выдаётся с aud, равным ему, — его сервер и сверяет.
//           serverClientId на iOS не нужен (его ждёт Android).
//       options.button = true       — выбор аккаунта каждый раз
//           (prompt=select_account), иначе Google может войти сам
//   options.silent = true            -> nil, "unsupported" у обоих: входа без
//       окна на iOS нет — повторный вход всегда показывает окно провайдера.
//   signin.signOut([listener])       -> true; событие isSignOut = true.
//       Забывать нечего: плагин ничего не хранит (Google — сессия Safari,
//       Apple выхода не знает). Отзывает доступ сервер (у Apple — REST API,
//       /auth/revoke) при удалении аккаунта.
//
// Событие слушателя — как у Android: name = "signin", provider ("apple" /
//   "google"), isError; при успехе idToken (JWT) и:
//     apple  — authorizationCode (сервер меняет его на refresh token, чтобы
//              отозвать при удалении аккаунта), user (постоянный номер
//              пользователя у команды разработчиков), email и displayName —
//              если Apple их передал;
//     google — displayName и profilePictureUri (из самого ID-токена);
//   при ошибке errorType ("cancelled", "failed") и errorMessage.
//
// Одновременно идёт один вход (любой из двух): второй, пока первый в полёте,
// -> nil, "busy". Итог отдаётся в главном потоке — в том же, где живёт Lua
// Solar2D на iOS. Закрыли состояние Lua (метка с __gc) — незавершённый вход
// молча забывается.
//
// ----------------------------------------------------------------------------

#if defined(__APPLE__)

#if !__has_feature(objc_arc)
#error "PluginSignIn.mm собирается с ARC (-fobjc-arc у файла в Plugin.xcodeproj)"
#endif

#include "PluginSignIn.h"

#include <CoronaAssert.h>
#include <CoronaLibrary.h>
#include <CoronaLua.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static const char kVersion[] = "1.2.0";
static const char kSobytie[] = "signin";

static NSString* const kGoogleAvtorizaciya = @"https://accounts.google.com/o/oauth2/v2/auth";
static NSString* const kGoogleTokeny = @"https://oauth2.googleapis.com/token";
static NSString* const kGoogleKonecKlienta = @".apps.googleusercontent.com";

// Состояние Lua, в котором загружен плагин. NULL — закрыто (или не открыто):
// событий в него больше не отдаём.
static lua_State* g_L = NULL;

// --- Окно и строки ---------------------------------------------------------

// Окно для окон входа: ключевое окно сцены, иначе любое окно приложения.
static UIWindow* KlyuchevoeOkno()
{
	UIWindow* lyuboe = nil;
	for (UIScene* scena in [UIApplication sharedApplication].connectedScenes) {
		if (![scena isKindOfClass:[UIWindowScene class]]) {
			continue;
		}
		for (UIWindow* okno in ((UIWindowScene*)scena).windows) {
			if (okno.isKeyWindow) {
				return okno;
			}
			if (!lyuboe) {
				lyuboe = okno;
			}
		}
	}
	return lyuboe;
}

static NSString* Base64Url(NSData* dannye)
{
	NSString* s = [dannye base64EncodedStringWithOptions:0];
	s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
	s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
	return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSData* IzBase64Url(NSString* s)
{
	NSMutableString* b = [[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
	[b replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b.length)];
	while (b.length % 4 != 0) {
		[b appendString:@"="];
	}
	return [[NSData alloc] initWithBase64EncodedString:b options:0];
}

// Случайная строка base64url из n байт (nil — генератор отказал).
static NSString* SluchaynayaStroka(size_t n)
{
	NSMutableData* d = [NSMutableData dataWithLength:n];
	if (SecRandomCopyBytes(kSecRandomDefault, n, d.mutableBytes) != errSecSuccess) {
		return nil;
	}
	return Base64Url(d);
}

static NSString* Sha256Base64Url(NSString* s)
{
	NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char hesh[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(d.bytes, (CC_LONG)d.length, hesh);
	return Base64Url([NSData dataWithBytes:hesh length:sizeof(hesh)]);
}

// Значение для тела application/x-www-form-urlencoded.
static NSString* DlyaFormy(NSString* s)
{
	static NSCharacterSet* mozhno = [NSCharacterSet characterSetWithCharactersInString:
		@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	return [s stringByAddingPercentEncodingWithAllowedCharacters:mozhno];
}

// Поля полезной нагрузки JWT (подпись не проверяется — её проверит сервер;
// здесь нужны только имя и фото для события).
static NSDictionary* PoleznayaNagruzka(NSString* jwt)
{
	NSArray<NSString*>* chasti = [jwt componentsSeparatedByString:@"."];
	if (chasti.count != 3) {
		return nil;
	}
	NSData* d = IzBase64Url(chasti[1]);
	if (!d) {
		return nil;
	}
	id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
	return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSString* Stroka(id znachenie)
{
	return [znachenie isKindOfClass:[NSString class]] ? znachenie : nil;
}

// --- Вход в полёте ---------------------------------------------------------

@interface PluginSignInVhod : NSObject <ASAuthorizationControllerPresentationContextProviding, ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, assign) lua_State* L;
@property (nonatomic, assign) CoronaLuaRef slushatel; // ссылка CoronaLuaNewRef
@property (nonatomic, copy) NSString* provayder;
- (void)otdatOshibku:(NSString*)tip tekst:(NSString*)tekst;
- (void)otdatUspeh:(NSDictionary<NSString*, NSString*>*)polya;
@end

// Вход в полёте: держит себя и контроллер/сессию (их делегаты — слабые ссылки).
static PluginSignInVhod* g_Idyot = nil;

@implementation PluginSignInVhod

// Отдать итог слушателю и освободить вход. Слушатель и ссылка — только пока
// жив тот же Lua.
- (void)otdat:(BOOL)oshibka polya:(NSDictionary<NSString*, NSString*>*)polya
{
	// Новый вход принимается уже из слушателя, но сами мы (и контроллер, и
	// сессия) живём до следующего витка главного цикла: они ещё внутри вызова,
	// который нас сюда привёл.
	PluginSignInVhod* uderzhat = self;
	dispatch_async(dispatch_get_main_queue(), ^{
		(void)uderzhat;
	});
	if (g_Idyot == self) {
		g_Idyot = nil;
	}
	lua_State* L = self.L;
	if (L == NULL || L != g_L || self.slushatel == 0) {
		return; // состояние Lua закрыто или итог уже отдан
	}
	CoronaLuaNewEvent(L, kSobytie);
	lua_pushstring(L, [self.provayder UTF8String]);
	lua_setfield(L, -2, "provider");
	lua_pushboolean(L, oshibka);
	lua_setfield(L, -2, "isError");
	for (NSString* pole in polya) {
		NSString* znachenie = polya[pole];
		if (znachenie.length > 0) {
			lua_pushstring(L, [znachenie UTF8String]);
			lua_setfield(L, -2, [pole UTF8String]);
		}
	}
	CoronaLuaRef slushatel = self.slushatel;
	self.slushatel = 0;
	CoronaLuaDispatchEvent(L, slushatel, 0);
	CoronaLuaDeleteRef(L, slushatel);
}

- (void)otdatOshibku:(NSString*)tip tekst:(NSString*)tekst
{
	[self otdat:YES polya:@{ @"errorType": tip ?: @"failed", @"errorMessage": tekst ?: @"" }];
}

- (void)otdatUspeh:(NSDictionary<NSString*, NSString*>*)polya
{
	[self otdat:NO polya:polya];
}

- (ASPresentationAnchor)presentationAnchorForAuthorizationController:(ASAuthorizationController*)controller
{
	return KlyuchevoeOkno();
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession*)session
{
	return KlyuchevoeOkno();
}

@end

// --- Вход с Apple ----------------------------------------------------------

@interface PluginSignInApple : PluginSignInVhod <ASAuthorizationControllerDelegate>
@property (nonatomic, strong) ASAuthorizationController* kontroller;
@end

@implementation PluginSignInApple

- (void)authorizationController:(ASAuthorizationController*)controller
    didCompleteWithAuthorization:(ASAuthorization*)authorization
{
	if (![authorization.credential isKindOfClass:[ASAuthorizationAppleIDCredential class]]) {
		[self otdatOshibku:@"failed" tekst:@"credential is not an Apple ID credential"];
		return;
	}
	ASAuthorizationAppleIDCredential* cr = (ASAuthorizationAppleIDCredential*)authorization.credential;
	NSString* token = cr.identityToken ? [[NSString alloc] initWithData:cr.identityToken encoding:NSUTF8StringEncoding] : nil;
	NSString* kod = cr.authorizationCode ? [[NSString alloc] initWithData:cr.authorizationCode encoding:NSUTF8StringEncoding] : nil;
	if (token.length == 0) {
		[self otdatOshibku:@"failed" tekst:@"Apple returned no identity token"];
		return;
	}
	// Имя — только при первом входе и только если его просили (fullName);
	// пустые части дают пустую строку, она в событие не попадёт.
	NSString* imya = nil;
	if (cr.fullName) {
		imya = [NSPersonNameComponentsFormatter localizedStringFromPersonNameComponents:cr.fullName
		                                                                          style:NSPersonNameComponentsFormatterStyleDefault
		                                                                        options:0];
	}
	NSMutableDictionary* polya = [NSMutableDictionary dictionary];
	polya[@"idToken"] = token;
	polya[@"authorizationCode"] = kod;
	polya[@"user"] = cr.user;
	polya[@"email"] = cr.email;
	polya[@"displayName"] = imya;
	[self otdatUspeh:polya];
}

- (void)authorizationController:(ASAuthorizationController*)controller
           didCompleteWithError:(NSError*)error
{
	// Отмена — закрыл шторку. Прочее (1000 — нет права «Вход с Apple» у
	// приложения или нет Apple ID на устройстве, сеть) — failed с кодом в тексте.
	NSString* tip = (error.code == ASAuthorizationErrorCanceled) ? @"cancelled" : @"failed";
	[self otdatOshibku:tip tekst:[NSString stringWithFormat:@"%@ (%ld)", error.localizedDescription ?: @"", (long)error.code]];
}

@end

// --- Вход через Google -----------------------------------------------------
//
// OAuth 2.0 для установленных приложений (RFC 8252) с PKCE (RFC 7636):
// страница входа Google открывается в ASWebAuthenticationSession — системном
// окне Safari с его cookie (вошедшему в Google в Safari хватает касания
// аккаунта), адрес возврата — обратный номер iOS-клиента
// (com.googleusercontent.apps.<номер>:/oauth2redirect); окно ловит его само,
// регистрировать схему в Info.plist не нужно. Код из адреса возврата
// меняется на токены прямым запросом к Google — секрета у iOS-клиента нет,
// доказательство — code_verifier. Из ответа нужен только id_token.

@interface PluginSignInGoogle : PluginSignInVhod
@property (nonatomic, strong) ASWebAuthenticationSession* sessiya;
@property (nonatomic, copy) NSString* klient;
@property (nonatomic, copy) NSString* vozvrat;
@property (nonatomic, copy) NSString* verifikator;
@property (nonatomic, copy) NSString* sostoyanie;
- (void)vernulsya:(NSURL*)adres oshibka:(NSError*)error; // итог окна входа
@end

@implementation PluginSignInGoogle

- (void)vernulsya:(NSURL*)adres oshibka:(NSError*)error
{
	if (error) {
		BOOL otmena = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain]
			&& error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
		[self otdatOshibku:(otmena ? @"cancelled" : @"failed")
		              tekst:[NSString stringWithFormat:@"%@ (%ld)", error.localizedDescription ?: @"", (long)error.code]];
		return;
	}
	NSURLComponents* chasti = [NSURLComponents componentsWithURL:adres resolvingAgainstBaseURL:NO];
	NSMutableDictionary<NSString*, NSString*>* parametry = [NSMutableDictionary dictionary];
	for (NSURLQueryItem* p in chasti.queryItems) {
		if (p.value) {
			parametry[p.name] = p.value;
		}
	}
	if (![parametry[@"state"] isEqualToString:self.sostoyanie]) {
		[self otdatOshibku:@"failed" tekst:@"state mismatch"];
		return;
	}
	if (parametry[@"error"]) {
		// access_denied — отказался на странице согласия
		NSString* tip = [parametry[@"error"] isEqualToString:@"access_denied"] ? @"cancelled" : @"failed";
		[self otdatOshibku:tip tekst:parametry[@"error"]];
		return;
	}
	NSString* kod = parametry[@"code"];
	if (kod.length == 0) {
		[self otdatOshibku:@"failed" tekst:@"no authorization code"];
		return;
	}

	NSMutableURLRequest* zapros = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGoogleTokeny]];
	zapros.HTTPMethod = @"POST";
	zapros.timeoutInterval = 30;
	[zapros setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	NSString* telo = [NSString stringWithFormat:@"grant_type=authorization_code&code=%@&client_id=%@&redirect_uri=%@&code_verifier=%@",
		DlyaFormy(kod), DlyaFormy(self.klient), DlyaFormy(self.vozvrat), DlyaFormy(self.verifikator)];
	zapros.HTTPBody = [telo dataUsingEncoding:NSUTF8StringEncoding];
	[[[NSURLSession sharedSession] dataTaskWithRequest:zapros
		completionHandler:^(NSData* dannye, NSURLResponse* otvet, NSError* oshibkaSeti) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[self tokeny:dannye otvet:otvet oshibka:oshibkaSeti];
			});
		}] resume];
}

- (void)tokeny:(NSData*)dannye otvet:(NSURLResponse*)otvet oshibka:(NSError*)oshibkaSeti
{
	if (oshibkaSeti) {
		[self otdatOshibku:@"failed" tekst:[NSString stringWithFormat:@"token request: %@", oshibkaSeti.localizedDescription]];
		return;
	}
	NSInteger kod = [otvet isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse*)otvet).statusCode : 0;
	id json = dannye ? [NSJSONSerialization JSONObjectWithData:dannye options:0 error:nil] : nil;
	NSDictionary* t = [json isKindOfClass:[NSDictionary class]] ? json : nil;
	NSString* token = Stroka(t[@"id_token"]);
	if (kod != 200 || token.length == 0) {
		NSString* prichina = Stroka(t[@"error_description"]) ?: Stroka(t[@"error"]) ?: @"no id_token";
		[self otdatOshibku:@"failed" tekst:[NSString stringWithFormat:@"token request %ld: %@", (long)kod, prichina]];
		return;
	}
	NSDictionary* nagruzka = PoleznayaNagruzka(token);
	NSMutableDictionary* polya = [NSMutableDictionary dictionary];
	polya[@"idToken"] = token;
	polya[@"displayName"] = Stroka(nagruzka[@"name"]);
	polya[@"profilePictureUri"] = Stroka(nagruzka[@"picture"]);
	[self otdatUspeh:polya];
}

@end

// --- Функции Lua -----------------------------------------------------------

static bool EtoSlushatel(lua_State* L, int index)
{
	return CoronaLuaIsListener(L, index, kSobytie);
}

static bool LogikaPolya(lua_State* L, int tablica, const char* pole)
{
	lua_getfield(L, tablica, pole);
	bool da = lua_toboolean(L, -1) != 0;
	lua_pop(L, 1);
	return da;
}

static NSString* StrokaPolya(lua_State* L, int tablica, const char* pole)
{
	lua_getfield(L, tablica, pole);
	NSString* s = nil;
	if (lua_type(L, -1) == LUA_TSTRING) {
		s = [NSString stringWithUTF8String:lua_tostring(L, -1)];
	}
	lua_pop(L, 1);
	return s;
}

// Общее начало apple() и google(): проверка аргументов (тип — ошибка
// программиста, значение — nil и сообщение, как в Lua-заглушке и на
// Android), очередь и тихий вход. 0 — можно начинать, иначе — число
// значений, уже положенных на стек.
static int NachaloVhoda(lua_State* L, const char* imya)
{
	if (!lua_istable(L, 1)) {
		return luaL_error(L, "signin.%s: options must be a table", imya);
	}
	if (!EtoSlushatel(L, 2)) {
		return luaL_error(L, "signin.%s: listener must be a function or a table", imya);
	}
	// Сначала очередь: пока вход в полёте, «busy» — на любой запрос
	if (g_Idyot != nil) {
		lua_pushnil(L);
		lua_pushstring(L, "busy");
		return 2;
	}
	if (LogikaPolya(L, 1, "silent")) {
		lua_pushnil(L);
		lua_pushstring(L, "unsupported"); // входа без окна на iOS нет
		return 2;
	}
	return 0;
}

static int l_version(lua_State* L)
{
	lua_pushstring(L, kVersion);
	return 1;
}

static int l_isAvailable(lua_State* L)
{
	lua_createtable(L, 0, 2);
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "google");
	lua_pushboolean(L, 1);
	lua_setfield(L, -2, "apple");
	return 1;
}

static int l_apple(lua_State* L)
{
	int n = NachaloVhoda(L, "apple");
	if (n > 0) {
		return n;
	}
	ASAuthorizationAppleIDProvider* provayder = [[ASAuthorizationAppleIDProvider alloc] init];
	ASAuthorizationAppleIDRequest* zapros = [provayder createRequest];
	NSMutableArray<ASAuthorizationScope>* oblasti = [NSMutableArray array];
	if (LogikaPolya(L, 1, "email")) {
		[oblasti addObject:ASAuthorizationScopeEmail];
	}
	if (LogikaPolya(L, 1, "fullName")) {
		[oblasti addObject:ASAuthorizationScopeFullName];
	}
	zapros.requestedScopes = oblasti;
	NSString* nonce = StrokaPolya(L, 1, "nonce");
	if (nonce) {
		zapros.nonce = nonce;
	}

	PluginSignInApple* vhod = [[PluginSignInApple alloc] init];
	vhod.L = L;
	vhod.provayder = @"apple";
	vhod.slushatel = CoronaLuaNewRef(L, 2);
	ASAuthorizationController* kontroller = [[ASAuthorizationController alloc] initWithAuthorizationRequests:@[ zapros ]];
	kontroller.delegate = vhod;
	kontroller.presentationContextProvider = vhod;
	vhod.kontroller = kontroller;
	g_Idyot = vhod;
	[kontroller performRequests];
	lua_pushboolean(L, 1);
	return 1;
}

static int l_google(lua_State* L)
{
	int n = NachaloVhoda(L, "google");
	if (n > 0) {
		return n;
	}
	NSString* klient = StrokaPolya(L, 1, "iosClientId");
	if (![klient hasSuffix:kGoogleKonecKlienta] || klient.length <= kGoogleKonecKlienta.length) {
		lua_pushnil(L);
		lua_pushstring(L, "iosClientId is required");
		return 2;
	}
	NSString* verifikator = SluchaynayaStroka(32);
	NSString* sostoyanie = SluchaynayaStroka(16);
	if (!verifikator || !sostoyanie) {
		lua_pushnil(L);
		lua_pushstring(L, "no random bytes");
		return 2;
	}
	// Схема возврата — обратный номер клиента: «123-abc.apps.googleusercontent.com»
	// -> «com.googleusercontent.apps.123-abc» (так её ждёт Google у iOS-клиента)
	NSString* skhema = [@"com.googleusercontent.apps." stringByAppendingString:
		[klient substringToIndex:klient.length - kGoogleKonecKlienta.length]];
	NSString* vozvrat = [skhema stringByAppendingString:@":/oauth2redirect"];

	NSURLComponents* adres = [NSURLComponents componentsWithString:kGoogleAvtorizaciya];
	NSMutableArray<NSURLQueryItem*>* p = [NSMutableArray arrayWithArray:@[
		[NSURLQueryItem queryItemWithName:@"client_id" value:klient],
		[NSURLQueryItem queryItemWithName:@"redirect_uri" value:vozvrat],
		[NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
		[NSURLQueryItem queryItemWithName:@"scope" value:@"openid email profile"],
		[NSURLQueryItem queryItemWithName:@"code_challenge" value:Sha256Base64Url(verifikator)],
		[NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
		[NSURLQueryItem queryItemWithName:@"state" value:sostoyanie],
	]];
	if (LogikaPolya(L, 1, "button")) {
		[p addObject:[NSURLQueryItem queryItemWithName:@"prompt" value:@"select_account"]];
	}
	adres.queryItems = p;

	PluginSignInGoogle* vhod = [[PluginSignInGoogle alloc] init];
	vhod.L = L;
	vhod.provayder = @"google";
	vhod.klient = klient;
	vhod.vozvrat = vozvrat;
	vhod.verifikator = verifikator;
	vhod.sostoyanie = sostoyanie;
	vhod.slushatel = CoronaLuaNewRef(L, 2);
	__weak PluginSignInGoogle* slabyy = vhod;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	ASWebAuthenticationSession* sessiya = [[ASWebAuthenticationSession alloc] initWithURL:adres.URL
		callbackURLScheme:skhema
		completionHandler:^(NSURL* callbackURL, NSError* error) {
			[slabyy vernulsya:callbackURL oshibka:error];
		}];
#pragma clang diagnostic pop
	sessiya.presentationContextProvider = vhod;
	// Cookie Safari — общие: вошедший в Google в Safari выбирает аккаунт касанием
	sessiya.prefersEphemeralWebBrowserSession = NO;
	vhod.sessiya = sessiya;
	g_Idyot = vhod;
	if (![sessiya start]) {
		g_Idyot = nil;
		CoronaLuaDeleteRef(L, vhod.slushatel);
		vhod.slushatel = 0;
		lua_pushnil(L);
		lua_pushstring(L, "web authentication session did not start");
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

static int l_signOut(lua_State* L)
{
	// Забывать нечего: плагин пользователя не хранит. Событие — следующим
	// витком главного цикла, как у Android (итог всегда асинхронный).
	if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
		if (!EtoSlushatel(L, 1)) {
			return luaL_error(L, "signin.signOut: listener must be a function or a table");
		}
		CoronaLuaRef ssylka = CoronaLuaNewRef(L, 1);
		lua_State* sostoyanie = L;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (sostoyanie != g_L) {
				return; // состояние Lua закрыто
			}
			CoronaLuaNewEvent(sostoyanie, kSobytie);
			lua_pushboolean(sostoyanie, 0);
			lua_setfield(sostoyanie, -2, "isError");
			lua_pushboolean(sostoyanie, 1);
			lua_setfield(sostoyanie, -2, "isSignOut");
			CoronaLuaDispatchEvent(sostoyanie, ssylka, 0);
			CoronaLuaDeleteRef(sostoyanie, ssylka);
		});
	}
	lua_pushboolean(L, 1);
	return 1;
}

// --- Метка состояния Lua ---------------------------------------------------

// Её сборка мусора — закрытие состояния (перезапуск проекта): незавершённый
// вход больше никому не отдаётся.
static const char kStateKey = 0;
static const char kStateMetatable[] = "plugin.signin.state";

static int l_state_gc(lua_State* L)
{
	if (g_L == L) {
		g_L = NULL;
	}
	if (g_Idyot != nil && g_Idyot.L == L) {
		g_Idyot = nil;
	}
	return 0;
}

// Заводит метку при первой загрузке плагина в этом состоянии Lua (повторная
// подменила бы прежнюю, и её __gc забыл бы живое состояние).
static void ZavestiMetku(lua_State* L)
{
	g_L = L;
	lua_pushlightuserdata(L, (void*)&kStateKey);
	lua_rawget(L, LUA_REGISTRYINDEX);
	bool uzhe = !lua_isnil(L, -1);
	lua_pop(L, 1);
	if (uzhe) {
		return;
	}
	lua_pushlightuserdata(L, (void*)&kStateKey);
	lua_newuserdata(L, 1);
	if (luaL_newmetatable(L, kStateMetatable)) {
		lua_pushcfunction(L, l_state_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	lua_rawset(L, LUA_REGISTRYINDEX);
}

// --- Регистрация плагина ---------------------------------------------------

// Загрузчик байт-кода Lua-части (CORONA_EXPORT уже включает extern "C")
CORONA_EXPORT int CoronaPluginLuaLoad_plugin_signin(lua_State*);

CORONA_EXPORT
int luaopen_plugin_signin(lua_State* L)
{
	ZavestiMetku(L);

	// Таблица библиотеки — из байт-кода Lua-части, нативные функции — поверх.
	lua_CFunction factory = Corona::Lua::Open<CoronaPluginLuaLoad_plugin_signin>;
	int result = CoronaLibraryNewWithFactory(L, factory, NULL, NULL);

	static const luaL_Reg kFunctions[] = {
		{ "version", l_version },
		{ "isAvailable", l_isAvailable },
		{ "apple", l_apple },
		{ "google", l_google },
		{ "signOut", l_signOut },
		{ NULL, NULL }
	};
	luaL_register(L, NULL, kFunctions);
	return result;
}

// Байт-код Lua-части (plugin_signin.c делает tools/obnovit_baitkod_lua.py из
// shared/plugin_signin.lua). Подключается после объявления
// CoronaPluginLuaLoad_…: так определение получает компоновку C из объявления.
#include "plugin_signin.c"

#endif // __APPLE__
