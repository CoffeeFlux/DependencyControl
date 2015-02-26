PreciseTimer = require "PreciseTimer.PreciseTimer"
ffi = require "ffi"

class Logger
    levels = {"fatal", "error", "warning", "hint", "debug", "trace"}
    defaultLevel: 2
    maxToFileLevel: 4
    fileBaseName: script_name
    fileSubName: ""
    logDir: "?user/log"
    fileTemplate: "%s/%s-%04x_%s_%s.log"
    fileMatchTemplate: "%d%d%d%d%-%d%d%-%d%d%-%d%d%-%d%d%-%d%d%-%x%x%x%x_@{fileBaseName}_?.*%.log$"
    prefix: ""
    toFile: false, toWindow: true
    indent: 0
    usePrefix: true
    indentStr: "—"
    maxFiles: 200, maxAge: 604800, maxSize:10*(10^6)

    Timer, seeded = PreciseTimer!, false

    new: (args) =>
        @[k] = v for k, v in pairs args

        -- scripts are loaded simultaneously, so we need to avoid seeding the rng with the same time
        unless seeded
            Timer\sleep 10 for i=1,50
            math.randomseed(Timer\timeElapsed!*1000000)
            math.random, math.random, math.random
            seeded = true

        @lastHadLineFeed = true
        escaped = @fileBaseName\gsub("([%%%(%)%[%]%.%*%-%+%?%$%^])","%%%1")
        @fileMatch = @fileMatchTemplate\gsub "@{fileBaseName}", escaped
        @fileName = @fileTemplate\format aegisub.decode_path(@logDir), os.date("%Y-%m-%d-%H-%M-%S"),
                                          math.random(0, 16^4-1), @fileBaseName, @fileSubName

    logEx: (level = @defaultLevel, msg = "", insertLineFeed = true, prefix = @prefix,  ...) =>
        return false if msg == ""

        prefix = "" unless @usePrefix
        lineFeed, indentStr = insertLineFeed and "\n" or "", ""
        if @indent>0 and @lastHadLineFeed
            indentRep = @indentStr\rep(@indent)
            indentStr = indentRep .. " "
            -- connect indentation supplied in the user message
            msg = msg\gsub("\n", "\n"..indentStr)\gsub "\n#{indentStr}(#{@indentStr})", "\n#{indentRep}%1"

        show = aegisub.log and @toWindow
        if @toFile and level <= @maxToFileLevel
            @handle = io.open(@fileName, "a") unless @handle
            linePre = @lastHadLineFeed and "#{indentStr}[#{levels[level]\upper!}] #{os.date '%H:%M:%S'} #{show and '+' or '•'} " or ""
            line = table.concat({linePre, prefix, msg, lineFeed})\format ...
            @handle\write(line)\flush!

        if level<2
            error "#{indentStr}Error: #{prefix}#{msg}"\format ...
        elseif show
            aegisub.log level, table.concat({indentStr, prefix, msg, lineFeed})\format ...

        @lastHadLineFeed = insertLineFeed
        return true

    log: (level, msg, ...) =>
        return false unless level or msg

        if "number" != type level
            return @logEx @defaultLevel, level, true, nil, msg, ...
        else return @logEx level, msg, true, nil, ...

    fatal: (...) => @log 0, ...
    error: (...) => @log 1, ...
    warn: (...) => @log 2, ...
    hint: (...) => @log 3, ...
    debug: (...) => @log 4, ...
    trace: (...) => @log 5, ...

    progress: (progress=false, msg = "", ...) =>
        if @progressStep and not progress
            @logEx nil, "■"\rep(10-@progressStep).."]", true, ""
            @progressStep = nil
        elseif progress
            unless @progressStep
                @progressStep = 0
                @logEx nil, "[", false, msg, ...
            step = math.floor(progress * 0.01 + 0.5) / 0.01
            @logEx nil, "■"\rep(step-@progressStep), false, ""

    -- taken from https://github.com/TypesettingCartel/Aegisub-Motion/blob/master/src/Log.moon
    dump: ( item, ignore, level = @defaultLevel ) =>
        if "table" != type item
            return @log level, item

        count, tablecount = 1, 1

        result = { "{ @#{tablecount}" }
        seen   = { [item]: tablecount }
        recurse = ( item, space ) ->
            for key, value in pairs item
                unless key == ignore
                    if "number" == type key
                        key = "##{key}"
                    if "table" == type value
                        unless seen[value]
                            tablecount += 1
                            seen[value] = tablecount
                            count += 1
                            result[count] = space .. "#{key}: { @#{tablecount}"
                            recurse value, space .. "    "
                            count += 1
                            result[count] = space .. "}"
                        else
                            count += 1
                            result[count] = space .. "#{key}: @#{seen[value]}"

                    else
                        if "string" == type value
                            value = ("%q")\format value

                        count += 1
                        result[count] = space .. "#{key}: #{value}"

        recurse item, "    "
        result[count+1] = "}"

        @log level, table.concat(result, "\n")

    windowError: ( errorMessage ) ->
        aegisub.dialog.display { { class: "label", label: errorMessage } }, { "&Close" }, { cancel: "&Close" }
        aegisub.cancel!


    trimFiles: (doWipe, maxAge = @maxAge, maxSize = @maxSize, maxFiles = @maxFiles) =>
        files, totalSize, deletedSize, now, f = {}, 0, 0, os.time!, 0

        dir = aegisub.decode_path @logDir
        lfs.chdir dir
        for file in lfs.dir dir
            attr = lfs.attributes file
            if type(attr) == "table" and attr.mode == "file" and file\find @fileMatch
                @log "!!2"
                f += 1
                files[f] = {name:file, modified:attr.modification, size:attr.size}

        table.sort files, (a,b) -> a.modified > b.modified
        total, kept = #files, 0

        for i, file in ipairs files
            totalSize += file.size
            if doWipe or kept > maxFiles or totalSize > maxSize or file.modified+maxAge < now
                deletedSize += file.size
                os.remove file.name
            else
                kept += 1
        return total-kept, deletedSize, total, totalSize
