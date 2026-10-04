local metadata =
{
	plugin =
	{
		format = 'staticLibrary',
		staticLibs = { 'plugin_signin', },
		frameworks = {},   -- системные фреймворки, нужные плагину: { 'Security', … }
		frameworksOptional = {},
		-- usesSwift = true,
	},
}

return metadata
