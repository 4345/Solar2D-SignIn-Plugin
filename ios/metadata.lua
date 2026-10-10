local metadata =
{
	plugin =
	{
		format = 'staticLibrary',
		staticLibs = { 'plugin_signin', },
		-- Вход с Apple и окно входа Google (AuthenticationServices), случайные
		-- байты PKCE (Security). Минимальная версия iOS 15 — оба есть всегда.
		frameworks = { 'AuthenticationServices', 'Security', },
		frameworksOptional = {},
		-- usesSwift = true,
	},
}

return metadata
