local function getConvar(name, default)
    local value = GetConvar(name, '')
    if value == nil or value == '' then return default end
    return value
end

Config.CADEndpoint = getConvar('CDE_CAD_API_URL', '')
Config.APIKey      = getConvar('CDE_CAD_API_KEY', '')

if Config.APIKey == '' then
    print('^1[CDE-ERS] CDE_CAD_API_KEY convar is not set. ERS bridge requests will fail. Add to server.cfg: set CDE_CAD_API_KEY "fvm_..."^0')
end
