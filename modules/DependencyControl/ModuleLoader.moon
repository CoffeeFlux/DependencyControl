-- Note: this is a private API intended to be exclusively for internal DependenyControl use
-- Everything in this class can and will change without any prior notice
-- and calling any method is guaranteed to interfere with DependencyControl operation
DependencyRecord = require "l0.DependencyControl.DependencyRecord"
Common = require "l0.DependencyControl.Common"

-- ModuleLoader is a static extension class to VersionRecord
-- As such all methods operate on VersionRecords, DummyRecords or DependencyRecords passed in by reference
class ModuleLoader
  msgs = {
    checkOptionalModules: {
      downloadHint: "Please download the modules in question manually, put them in your %s folder and reload your automation scripts."
      missing: "Error: a %s feature you're trying to use requires additional modules that were not found on your system:\n%s\n%s"
    }
    formatVersionErrorTemplate: {
      missing: "— %s %s%s\n—— Reason: %s"
      outdated: "— %s (Installed: v%s; Required: v%s)%s\n—— Reason: %s"
    }
    loadModule: {
      moduleMissing: "Module '%s' was reported as missing by package '%s'."
      loadFailed: "Package '%s' failed to load module '%s': %s"
    }
    loadModules: {
      missing: "Error: one or more of the modules required by %s could not be found on your system:\n%s\n%s"
      missingRecord: "Error: module '%s' is missing a version record."
      moduleError: "Error in required module %s:\n%s"
      outdated: [[Error: one or more of the modules required by %s are outdated on your system:
%s\nPlease update the modules in question manually and reload your automation scripts.]]
    }
  }

  @formatVersionErrorTemplate = (name, reqVersion, url, reason, ref) =>
    url = url and ": #{url}" or ""
    if ref
      version = @@parseVersion ref.version
      return msgs.formatVersionErrorTemplate.outdated\format name, version, reqVersion, url, reason
    else
      reqVersion = reqVersion and " (v#{reqVersion})" or ""
      return msgs.formatVersionErrorTemplate.missing\format name, reqVersion, url, reason

  
  -- Our global module registry allows for circular dependencies.
  -- In order to resolve those, we set a dummy reference to not-yet-loaded modules
  -- which allows them to find each other
  @createDummyRef = =>
    return nil if @record.scriptType != DependencyRecord.ScriptType.Module

    export LOADED_MODULES = {} unless LOADED_MODULES
    unless LOADED_MODULES[@record.namespace]
      @ref = {}
      LOADED_MODULES[@record.namespace] = setmetatable {__depCtrlDummy: true, version: @}, @ref
      return true
    return false

  @removeDummyRef = =>
    return nil if @record.scriptType != DependencyRecord.ScriptType.Module
    if LOADED_MODULES[@record.namespace] and LOADED_MODULES[@record.namespace].__depCtrlDummy
      LOADED_MODULES[@record.namespace] = nil
      return true
    return  false

  @loadModule = (mdl, usePrivate, reload) =>
    runInitializer = (ref) ->
      return unless type(ref) == "table" and ref.__depCtrlInit
      -- Note to future self: don't change this to a class check! When DepCtrl self-updates
      -- any managed module initialized before will still use the same instance
      if type(ref.version) != "table" or ref.version.__name != @@__name
        ref.__depCtrlInit @@

    with mdl
      ._missing, ._error = nil

      moduleName = usePrivate and "#{@record.namespace}.#{mdl.moduleName}" or .moduleName
      name = "#{mdl.name or mdl.moduleName}#{usePrivate and ' (Private Copy)' or ''}"

      if .outdated or reload
        -- clear old references
        package.loaded[moduleName], LOADED_MODULES[moduleName] = nil

      elseif ._ref = LOADED_MODULES[moduleName]
        -- module is already loaded, however it may or may not have been loaded by DepCtrl
        -- so we have to call any DepCtrl initializer if it hasn't been called yet
        runInitializer ._ref
        return ._ref

      loaded, res = xpcall require, debug.traceback, moduleName
      unless loaded
        LOADED_MODULES[moduleName] = nil
        res or= "unknown error"
        ._missing = nil != res\find "module '#{moduleName}' not found:", nil, true
        if not ._missing
          @@logger\debug msgs.loadModule.loadFailed, @record.namespace, moduleName, res
          ._error = res
        elseif not usePrivate
          @@logger\debug msgs.loadModule.moduleMissing, moduleName, @record.namespace

        return nil

      -- set new references
      if reload and ._ref and ._ref.__depCtrlDummy
        setmetatable ._ref, res
      ._ref, LOADED_MODULES[moduleName] = res, res

      -- run DepCtrl initializer if one was specified
      runInitializer res

    return mdl._ref  -- having this in the with block breaks moonscript

  @loadModules = (modules, addFeeds = {@record.feed}, skip = @record.moduleName and {[@record.moduleName]: true} or {}) =>
    for mdl in *modules
      continue if skip[mdl]
      with mdl
        ._ref, ._updated, ._missing, ._outdated, ._reason, ._error = nil

        -- try to load private copies of required modules first
        ModuleLoader.loadModule @, mdl, true
        ModuleLoader.loadModule @, mdl unless ._ref

        -- try to fetch and load a missing module from the web
        if ._missing
          record = DependencyRecord moduleName: .moduleName, name: .name, url: .url, feed: .feed
          ._ref, code, extErr = @@updater\require record, .version, addFeeds, .optional
          if ._ref or .optional
            ._updated, ._missing = true, false
          else
            ._reason = @@updater\getUpdaterErrorMsg code, .name or .moduleName, true, true, extErr
            -- nuke dummy reference for circular dependencies
            LOADED_MODULES[.moduleName] = nil

        -- check if the version requirements are satisfied
        -- which is guaranteed for modules updated with \require, so we don't need to check again
        if .version and ._ref and not ._updated
          version = ._ref.version
          unless version
            ._error = msgs.loadModules.missingRecord\format .moduleName
            continue

          -- if version field is not a DepCtrl instance, we need to create an unmanaged record
          record = if type(version) == "table" and version.__class == @@
            version.record
          else DependencyRecord moduleName: .moduleName, version: version, 
                                recordType: DependencyRecord.RecordType.Unmanaged

          -- force an update for outdated modules
          if not record\checkVersion .version
            ref, code, extErr = @@updater\require record, .version, addFeeds
            if ref
              ._ref = ref
            elseif not .optional
              ._outdated = true
              ._reason = @@updater\getUpdaterErrorMsg code, .name or .moduleName, true, false, extErr
          else
            -- perform regular update check if we can get a lock without waiting
            -- right now we don't care about the result and don't reload the module
            -- so the update will not be effective until the user restarts Aegisub
            -- or reloads the script
            @@updater\scheduleUpdate record

    missing, outdated, moduleError = {}, {}, {}
    for mdl in *modules
      with mdl
        name = .name or .moduleName
        if ._missing
          missing[#missing+1] = ModuleLoader.formatVersionErrorTemplate @, name, .version, .url, ._reason
        elseif ._outdated
          outdated[#outdated+1] = ModuleLoader.formatVersionErrorTemplate @, name, .version, .url, ._reason, ._ref
        elseif ._error
          moduleError[#moduleError+1] = msgs.loadModules.moduleError\format name, ._error

    errorMsg = {}
    if #moduleError > 0
      errorMsg[1] = table.concat moduleError, "\n"
    if #outdated > 0
      errorMsg[#errorMsg+1] = msgs.loadModules.outdated\format @record.name, table.concat outdated, "\n"
    if #missing > 0
      errorMsg[#errorMsg+1] = msgs.loadModules.missing\format @record.name, table.concat(missing, "\n"), 
                              msgs.checkOptionalModules.downloadHint

    return #errorMsg == 0, table.concat(errorMsg, "\n\n")

  @checkOptionalModules = (modules) =>
    modules = type(modules)=="string" and {[modules]:true} or {mdl,true for mdl in *modules}
    missing = [ModuleLoader.formatVersionErrorTemplate @, mdl.moduleName, mdl.version, mdl.url,
              mdl._reason for mdl in *@record.requiredModules when mdl.optional and mdl._missing and modules[mdl.name]]

    if #missing>0
      downloadHint = msgs.checkOptionalModules.downloadHint\format Common.Directories.Script[DependencyRecord.ScriptType.Module]
      errorMsg = msgs.checkOptionalModules.missing\format @record.name, table.concat(missing, "\n"), downloadHint
      return false, errorMsg
    return true