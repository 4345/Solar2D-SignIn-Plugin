package plugin.signin;

import android.app.Activity;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;

import androidx.credentials.ClearCredentialStateRequest;
import androidx.credentials.Credential;
import androidx.credentials.CredentialManager;
import androidx.credentials.CredentialManagerCallback;
import androidx.credentials.CustomCredential;
import androidx.credentials.GetCredentialRequest;
import androidx.credentials.GetCredentialResponse;
import androidx.credentials.exceptions.ClearCredentialException;
import androidx.credentials.exceptions.GetCredentialCancellationException;
import androidx.credentials.exceptions.GetCredentialException;
import androidx.credentials.exceptions.GetCredentialInterruptedException;
import androidx.credentials.exceptions.NoCredentialException;

import com.ansca.corona.CoronaEnvironment;
import com.ansca.corona.CoronaLua;
import com.ansca.corona.CoronaRuntime;
import com.ansca.corona.CoronaRuntimeTask;
import com.ansca.corona.CoronaRuntimeTaskDispatcher;
import com.google.android.libraries.identity.googleid.GetGoogleIdOption;
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption;
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential;
import com.naef.jnlua.JavaFunction;
import com.naef.jnlua.LuaRuntimeException;
import com.naef.jnlua.LuaState;
import com.naef.jnlua.LuaType;
import com.naef.jnlua.NamedJavaFunction;

import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * plugin.signin на Android: вход через Google средствами Credential Manager
 * (androidx.credentials + googleid). Приложение получает ID-токен Google и
 * само проверяет его на своём сервере.
 *
 * Lua API:
 *   signin.version()                         -> "1.0.0"
 *   signin.isAvailable()                     -> { google = true, apple = false }
 *   signin.google(options, listener)         -> true | nil, сообщение
 *       options.serverClientId (строка, обязательно) — веб-клиент OAuth
 *       options.silent (логическое) — только уже разрешённые этому приложению
 *           аккаунты, без окна выбора; нет такого — ошибка noCredential
 *       options.nonce (строка) — попадёт в ID-токен
 *   signin.apple(options, listener)          -> nil, "unsupported"
 *   signin.signOut([listener])               -> сбросить выбор аккаунта
 *
 * Событие слушателя: name = "signin", provider = "google", isError;
 *   при успехе idToken; при ошибке errorType ("cancelled", "noCredential",
 *   "interrupted", "failed") и errorMessage. После signOut: isSignOut = true.
 *
 * Слушатель зовётся в потоке Lua (CoronaRuntimeTaskDispatcher), а не в
 * потоке ответа системы. Одновременно идёт один вход: второй, пока первый в
 * полёте, получает nil, "busy".
 */
public class LuaLoader implements JavaFunction {

    static final String VERSION = "1.0.0";
    static final String SOBYTIE = "signin";

    private static final AtomicBoolean idyot = new AtomicBoolean(false);

    @Override
    public int invoke(LuaState L) {
        NamedJavaFunction[] funkcii = {
            new Version(), new IsAvailable(), new Google(), new Apple(), new SignOut(),
        };
        L.register(L.toString(1), funkcii);
        return 1;
    }

    private static Executor glavnyyPotok() {
        Handler h = new Handler(Looper.getMainLooper());
        return h::post;
    }

    private static void oshibkaArgumenta(String tekst) {
        throw new LuaRuntimeException(tekst);
    }

    private static String strokaPolya(LuaState L, int tablica, String pole) {
        L.getField(tablica, pole);
        String s = L.type(-1) == LuaType.STRING ? L.toString(-1) : null;
        L.pop(1);
        return s;
    }

    private static boolean logikaPolya(LuaState L, int tablica, String pole) {
        L.getField(tablica, pole);
        boolean b = L.toBoolean(-1);
        L.pop(1);
        return b;
    }

    /**
     * Итог — в поток Lua, слушателю; ссылка на слушателя освобождается там же.
     * Ошибка — когда задан tipOshibki (у успешного выхода нет ни токена, ни ошибки).
     */
    private static void otvetit(CoronaRuntimeTaskDispatcher dispetcher, final int ssylka,
                                final String token, final String tipOshibki, final String tekstOshibki,
                                final boolean vyhod) {
        dispetcher.send(new CoronaRuntimeTask() {
            @Override
            public void executeUsing(CoronaRuntime runtime) {
                LuaState L = runtime.getLuaState();
                try {
                    CoronaLua.newEvent(L, SOBYTIE);
                    L.pushString("google");
                    L.setField(-2, "provider");
                    L.pushBoolean(tipOshibki != null);
                    L.setField(-2, "isError");
                    if (vyhod) {
                        L.pushBoolean(true);
                        L.setField(-2, "isSignOut");
                    }
                    if (token != null) {
                        L.pushString(token);
                        L.setField(-2, "idToken");
                    }
                    if (tipOshibki != null) {
                        L.pushString(tipOshibki);
                        L.setField(-2, "errorType");
                        L.pushString(tekstOshibki == null ? "" : tekstOshibki);
                        L.setField(-2, "errorMessage");
                    }
                    CoronaLua.dispatchEvent(L, ssylka, 0);
                } catch (Exception e) {
                    e.printStackTrace();
                } finally {
                    CoronaLua.deleteRef(L, ssylka);
                }
            }
        });
    }

    private static class Version implements NamedJavaFunction {
        @Override public String getName() { return "version"; }
        @Override public int invoke(LuaState L) {
            L.pushString(VERSION);
            return 1;
        }
    }

    private static class IsAvailable implements NamedJavaFunction {
        @Override public String getName() { return "isAvailable"; }
        @Override public int invoke(LuaState L) {
            L.newTable();
            L.pushBoolean(true);
            L.setField(-2, "google");
            L.pushBoolean(false);
            L.setField(-2, "apple");
            return 1;
        }
    }

    private static class Apple implements NamedJavaFunction {
        @Override public String getName() { return "apple"; }
        @Override public int invoke(LuaState L) {
            L.pushNil();
            L.pushString("unsupported");
            return 2;
        }
    }

    private static class Google implements NamedJavaFunction {
        @Override public String getName() { return "google"; }

        @Override
        public int invoke(LuaState L) {
            if (L.type(1) != LuaType.TABLE) {
                oshibkaArgumenta("signin.google: options must be a table");
            }
            if (!CoronaLua.isListener(L, 2, SOBYTIE)) {
                oshibkaArgumenta("signin.google: listener must be a function or a table");
            }
            final String klient = strokaPolya(L, 1, "serverClientId");
            final boolean tikho = logikaPolya(L, 1, "silent");
            final String nonce = strokaPolya(L, 1, "nonce");
            if (klient == null || klient.isEmpty()) {
                L.pushNil();
                L.pushString("serverClientId is required");
                return 2;
            }
            final Activity activity = CoronaEnvironment.getCoronaActivity();
            if (activity == null) {
                L.pushNil();
                L.pushString("no activity");
                return 2;
            }
            if (!idyot.compareAndSet(false, true)) {
                L.pushNil();
                L.pushString("busy");
                return 2;
            }
            final int ssylka = CoronaLua.newRef(L, 2);
            final CoronaRuntimeTaskDispatcher dispetcher = new CoronaRuntimeTaskDispatcher(L);

            activity.runOnUiThread(() -> {
                try {
                    nachat(activity, klient, tikho, nonce, dispetcher, ssylka);
                } catch (Throwable t) {
                    idyot.set(false);
                    otvetit(dispetcher, ssylka, null, "failed", t.toString(), false);
                }
            });
            L.pushBoolean(true);
            return 1;
        }

        private void nachat(Activity activity, String klient, boolean tikho, String nonce,
                            CoronaRuntimeTaskDispatcher dispetcher, int ssylka) {
            GetCredentialRequest.Builder zapros = new GetCredentialRequest.Builder();
            if (tikho) {
                // Повторный вход без окна: только аккаунты, уже разрешённые этому
                // приложению, и автовыбор, если такой один.
                GetGoogleIdOption.Builder b = new GetGoogleIdOption.Builder()
                    .setServerClientId(klient)
                    .setFilterByAuthorizedAccounts(true)
                    .setAutoSelectEnabled(true);
                if (nonce != null) b.setNonce(nonce);
                zapros.addCredentialOption(b.build());
            } else {
                // Кнопка «Войти через Google»: окно выбора любого аккаунта устройства.
                GetSignInWithGoogleOption.Builder b = new GetSignInWithGoogleOption.Builder(klient);
                if (nonce != null) b.setNonce(nonce);
                zapros.addCredentialOption(b.build());
            }

            CredentialManager.create(activity).getCredentialAsync(activity, zapros.build(),
                new CancellationSignal(), glavnyyPotok(),
                new CredentialManagerCallback<GetCredentialResponse, GetCredentialException>() {
                    @Override
                    public void onResult(GetCredentialResponse otvet) {
                        idyot.set(false);
                        Credential c = otvet.getCredential();
                        if (c instanceof CustomCredential
                                && GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL.equals(c.getType())) {
                            try {
                                String token = GoogleIdTokenCredential.createFrom(c.getData()).getIdToken();
                                otvetit(dispetcher, ssylka, token, null, null, false);
                            } catch (Exception e) {
                                otvetit(dispetcher, ssylka, null, "failed", "token parse: " + e, false);
                            }
                        } else {
                            otvetit(dispetcher, ssylka, null, "failed", "unexpected credential: " + c.getType(), false);
                        }
                    }

                    @Override
                    public void onError(GetCredentialException e) {
                        idyot.set(false);
                        String tip = "failed";
                        if (e instanceof GetCredentialCancellationException) {
                            tip = "cancelled";
                        } else if (e instanceof NoCredentialException) {
                            tip = "noCredential";
                        } else if (e instanceof GetCredentialInterruptedException) {
                            tip = "interrupted";
                        }
                        otvetit(dispetcher, ssylka, null, tip, e.getType() + ": " + e.getMessage(), false);
                    }
                });
        }
    }

    private static class SignOut implements NamedJavaFunction {
        @Override public String getName() { return "signOut"; }

        @Override
        public int invoke(LuaState L) {
            final boolean estSlushatel = CoronaLua.isListener(L, 1, SOBYTIE);
            final int ssylka = estSlushatel ? CoronaLua.newRef(L, 1) : 0;
            final CoronaRuntimeTaskDispatcher dispetcher = estSlushatel ? new CoronaRuntimeTaskDispatcher(L) : null;
            final Activity activity = CoronaEnvironment.getCoronaActivity();
            if (activity == null) {
                if (estSlushatel) otvetit(dispetcher, ssylka, null, "failed", "no activity", true);
                L.pushBoolean(false);
                return 1;
            }
            CredentialManager.create(activity).clearCredentialStateAsync(new ClearCredentialStateRequest(),
                new CancellationSignal(), glavnyyPotok(),
                new CredentialManagerCallback<Void, ClearCredentialException>() {
                    @Override
                    public void onResult(Void v) {
                        if (estSlushatel) otvetit(dispetcher, ssylka, null, null, null, true);
                    }

                    @Override
                    public void onError(ClearCredentialException e) {
                        if (estSlushatel) otvetit(dispetcher, ssylka, null, "failed", e.getType() + ": " + e.getMessage(), true);
                    }
                });
            L.pushBoolean(true);
            return 1;
        }
    }
}
