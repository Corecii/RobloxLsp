local config    = require 'config'
local define    = require 'proto.define'
local files     = require 'files'
local guide     = require 'core.guide'
local lang      = require 'language'
local rbxlibs   = require 'library.rbxlibs'
local rojo      = require 'library.rojo'
local util      = require 'utility'
local vm        = require 'vm'

local undefinedType    = require 'core.diagnostics.undefined-type'
local redefinedType    = require 'core.diagnostics.redefined-type'
local invalidClassName = require 'core.diagnostics.invalid-class-name'

local m = {}

local nilType = {
    type = "type.name",
    [1] = "nil"
}

local anyType = {
    type = "type.name",
    [1] = "any"
}

local stringType = {
    type = "type.name",
    [1] = "string"
}

local numberType = {
    type = "type.name",
    [1] = "number"
}

local inferOptions = {
    skipDoc = true,
    onlyDef = true,
    sameFile = true
}

local function buildType(tp)
    if config.config.typeChecking.showFullType then
        tp = m.normalizeType(tp)
    end
    return guide.buildTypeAnn(tp)
end

local function getSimpleString(source)
    local simple = guide.getSimple(source)
    if simple then
        local concat = {}
        for _, node in ipairs(simple) do
            if type(node) == "string" then
                concat[#concat+1] = node
            else
                concat[#concat+1] = ""
            end
        end
        return table.concat(concat, ".")
    end
    return nil
end

local function isIndexValue(obj)
    if obj.original then
        obj = obj.original
    end
    if obj.parent then
        return obj.parent.type == "type.index"
            or obj.parent.type == "type.table"
    end
    return false
end

local function checkFieldOfTable(source, get)
    local key = guide.getKeyName(get)
    for _, field in ipairs(source) do
        if field.type == "tablefield"
        or field.type == "tableindex" then
            if guide.getKeyName(field) == key then
                return field
            end
        end
    end
    local simple = getSimpleString(source.parent)
    if not simple then
        return nil
    end
    get = guide.getRoot(source) == guide.getRoot(get) and get or source
    local result = guide.eachSourceBetween(guide.getParentBlock(source), source.finish, math.huge, function (field)
        if field.type == "setfield"
        or field.type == "setmethod"
        or field.type == "setindex" then
            if guide.getKeyName(field) == key
            and guide.hasParent(get, guide.getParentFunction(field))
            and getSimpleString(field.node) == simple then
                return field
            end
        end
    end)
    return result
end

local function getFieldsOfTable(source)
    local fields = {}
    for _, field in ipairs(source) do
        if field.type == "tablefield"
        or field.type == "tableindex" then
            fields[#fields+1] = field
        end
    end
    local simple = getSimpleString(source.parent)
    if not simple then
        return fields
    end
    guide.eachSourceBetween(guide.getParentBlock(source), source.finish, math.huge, function (field)
        if field.type == "setfield"
        or field.type == "setmethod"
        or field.type == "setindex" then
            if getSimpleString(field.node) == simple then
                fields[#fields+1] = field
            end
        end
    end)
    return fields
end

function m.checkRequire(func)
    local call = func.next
    if call and call.args then
        local reqScript = call.args[1]
        for _, def in ipairs(vm.getDefs(reqScript, 0)) do
            if def.uri then
                local lib = rojo:matchLibrary(def.uri)
                if lib then
                    return lib
                end
                if not files.eq(guide.getUri(reqScript), def.uri) then
                    local ast = files.getAst(def.uri)
                    if ast and ast.ast.returns then
                        if #ast.ast.returns == 1 then
                            return ast.ast.returns[1][1]
                        end
                        break
                    end
                end
            end
        end
    end
end

function m.checkDefinition(source, simple, other)
    if not source then
        return false
    end
    if source.type == "type.assert" then
        return true
    end
    if not simple then
        simple = other or {}
        if source.type == "select" then
            source = source.vararg
        end
        if source.node then
            local node = source
            table.insert(simple, 1, node)
            while node.node do
                if node.iterator then
                    return false
                end
                node = node.node
                table.insert(simple, 1, node)
            end
        end
    end
    local node = table.remove(simple, 1)
    if not node then
        return true
    end
    if node.type == "local" then
        local get = table.remove(simple, 1)
        if node.typeAnn or node.tag == "_ENV" then
            if get and get.special == "require" then
                return m.checkDefinition(get, simple)
            end
            return true
        end
        if node.value then
            if guide.isLiteral(node.value) then
                return m.checkDefinition(node.value, simple)
            elseif m.options["recursive-get-type"] then
                return m.checkDefinition(node.value, nil, simple)
            end
        else
            return true
        end
    elseif node.type == "getfield" or node.type == "getindex" or node.type == "getmethod" then
        if source.type == "table" then
            if guide.getKeyName(node) then
                local field = checkFieldOfTable(source, node)
                if field and field.value then
                    if guide.isLiteral(field.value) then
                        return m.checkDefinition(field.value, simple)
                    elseif m.options["recursive-get-type"] then
                        return m.checkDefinition(field.value, nil, simple)
                    end
                end
            end
        end
    elseif node.type == "call" then
        if source.special == "require" then
            local ret = m.checkRequire(source)
            if ret then
                if ret.type == "type.name" then
                    return true
                end
                if guide.isLiteral(ret) then
                    return m.checkDefinition(ret, simple)
                elseif m.options["recursive-get-type"] then
                    return m.checkDefinition(ret, nil, simple)
                end
            end
        end
        if source.type == "function" and source.returnTypeAnn then
            return true
        end
    end
    return false
end

function m.normalizeType(tp)
    local original = tp
    if m.cache.normalize[original] then
        return m.cache.normalize[original]
    end
    local optional = tp.optional
    local readOnly = tp.readOnly
    while tp.type == "paren" do
        optional = tp.optional or optional
        tp = tp.exp
        if not tp then
            return anyType
        end
    end
    optional = tp.optional or optional
    if tp.type == "type.table" then
        for i, field in ipairs(tp) do
            if field.type ~= "type.index" and field.type ~= "type.field" then
                tp = util.shallowCopy(tp)
                tp[i] = {
                    type = "type.index",
                    key = numberType,
                    value = field
                }
                break
            end
        end
    end
    if tp.type == "type.typeof" then
        if tp.parent and guide.getParentType(tp, "type.alias") then
            inferOptions.searchFrom = guide.getParentBlock(tp)
        else
            inferOptions.searchFrom = tp.value
        end
        local value = m.getType(tp.value)
        inferOptions.searchFrom = nil
        return m.normalizeType(value)
    end
    if tp.type == "type.module" then
        local alias = vm.getModuleTypeAlias(tp)
        if alias then
            tp = util.shallowCopy(tp[2])
            tp.typeAlias = alias
        end
    end
    if tp.type == "type.name" then
        local value = m.getTypeFromAlias(tp)
        if value ~= tp then
            m.cache.normalize[tp] = anyType
            tp = m.normalizeType(value)
        end
    end
    if readOnly then
        tp = util.shallowCopy(tp)
        tp.readOnly = true
    end
    if optional then
        local copy = util.shallowCopy(tp)
        copy.optional = false
        tp = {
            type = "type.union",
            [1] = copy,
            [2] = nilType,
            start = tp.start,
            finish = tp.finish,
        }
    end
    m.cache.normalize[original] = tp
    return tp
end

function m.getTypeFromAlias(tp)
    if tp.typeAlias then
        if tp.generics and tp.typeAlias.generics then
            return guide.copyTypeWithGenerics(
                tp.typeAlias.value,
                guide.getGenericsReplace(tp.typeAlias, tp.generics)
            )
        else
            return tp.typeAlias.value
        end
    end
    return tp
end

function m.getType(source)
    if not source then
        return nilType
    end
    while source.type == "paren" do
        source = source.exp
        if not source then
            return anyType
        end
    end
    if guide.isTypeAnn(source) then
        return source
    end
    if m.cache.type[source] then
        return m.cache.type[source]
    end
    if not m.strict and not m.checkDefinition(source) then
        m.cache.type[source] = anyType
        return anyType
    end
    local infers = vm.getInfers(source, 0, inferOptions)
    if #infers == 0 then
        m.cache.type[source] = anyType
        return anyType
    end
    local tp = {
        type = "type.union"
    }
    local metatable = nil
    for _, infer in ipairs(infers) do
        if guide.isTypeAnn(infer.source) then
            tp[#tp+1] = infer.source
        elseif infer.meta then
            metatable = m.convertToType(infer, infer.meta.value, source)
        else
            tp[#tp+1] = m.convertToType(infer, source)
        end
    end
    if #tp == 1 then
        tp = tp[1]
    elseif #tp == 0 then
        m.cache.type[source] = anyType
        return anyType
    end
    if metatable then
        tp = {
            type = "type.meta",
            [1] = tp,
            [2] = metatable
        }
    end
    m.cache.type[source] = tp
    return tp
end

function m.hasTypeAnn(source, checkFunc)
    if guide.isTypeAnn(source) then
        return true
    end
    if not m.strict and not m.checkDefinition(source) then
        return false
    end
    for _, infer in ipairs(vm.getInfers(source, 0, inferOptions)) do
        if guide.isTypeAnn(infer.source) then
            return true
        elseif infer.source.type == "string" then
            return true
        elseif checkFunc and infer.source.type == "function" then
            if infer.source.returnTypeAnn then
                return true
            end
            if infer.source.args then
                for _, arg in ipairs(infer.source.args) do
                    if arg.typeAnn then
                        return true
                    end
                end
            end
        end
    end
    return false
end

function m.convertToType(infer, get, searchFrom)
    local source = infer.source
    if source then
        if m.cache.convert[source] then
            return m.cache.convert[source]
        end
        if source.type == "table" then
            local tp = {
                type = "type.table",
                inferred = source
            }
            m.cache.convert[source] = tp
            inferOptions.searchFrom = inferOptions.searchFrom or searchFrom or get
            local fields
            if get == source then
                fields = {}
                for _, field in ipairs(source) do
                    if field.type == "tablefield" or field.type == "tableindex" then
                        fields[#fields+1] = field
                    end
                end
            else
                if get.type == "tablefield" or get.type == "tableindex" then
                    get = get.value
                end
                inferOptions.skipMeta = true
                fields = vm.getFields(get, 0, inferOptions)
                inferOptions.skipMeta = nil
            end
            for _, value in ipairs(source) do
                if value.type ~= "tablefield" and value.type ~= "tableindex" then
                    fields[#fields+1] = {
                        index = numberType,
                        value = value,
                    }
                end
            end
            local checked = {}
            local indexType = nil
            for _, field in ipairs(fields) do
                local valueType = m.getType(field.type and field or field.value)
                if valueType.type ~= "paren" then
                    valueType = guide.getObjectValue(valueType) or valueType
                end
                if guide.getKeyType(field) == "string" then
                    local key = guide.getKeyName(field)
                    if key then
                        if checked[key] then
                            if not m.compareTypes(valueType, checked[key].value) then
                                checked[key].value[#checked[key].value+1] = valueType
                            end
                        else
                            tp[#tp+1] = {
                                type = "type.field",
                                key = {key},
                                value = {
                                    type = "type.union",
                                    [1] = valueType
                                }
                            }
                            checked[key] = tp[#tp]
                        end
                    end
                elseif field.index then
                    local keyType = m.getType(field.index)
                    if indexType then
                        if not m.compareTypes(keyType, indexType.key) then
                            indexType.key[#indexType.key+1] = keyType
                        end
                        if not m.compareTypes(valueType, indexType.value) then
                            indexType.value[#indexType.value+1] = valueType
                        end
                    else
                        tp[#tp+1] = {
                            type = "type.index",
                            key = {
                                type = "type.union",
                                [1] = keyType
                            },
                            value = {
                                type = "type.union",
                                [1] = valueType
                            }
                        }
                        indexType = tp[#tp]
                    end
                end
            end
            if inferOptions.searchFrom == (searchFrom or get) then
                inferOptions.searchFrom = nil
            end
            for _, field in ipairs(tp) do
                if field.type == "type.index" then
                    if #field.key == 1 then
                        field.key = field.key[1]
                    end
                end
                if #field.value == 1 then
                    field.value = field.value[1]
                end
            end
            return tp
        elseif source.type == "function" then
            local tp = {
                type = "type.function",
                args = {
                    type = "type.list",
                    funcargs = true
                },
                returns = anyType,
                inferred = source
            }
            m.cache.convert[source] = tp
            if source.args then
                for _, arg in ipairs(source.args) do
                    local argType = arg.typeAnn and arg.typeAnn.value or {
                        [1] = "any",
                        type = "type.name"
                    }
                    if arg.type == "..." then
                        tp.args[#tp.args+1] = {
                            type = "type.variadic",
                            value = argType
                        }
                    else
                        argType.paramName = {arg[1]}
                        tp.args[#tp.args+1] = argType
                    end
                end
            end
            if source.returnTypeAnn then
                tp.returns = source.returnTypeAnn.value
            elseif m.strict then
                if not source.returns then
                    tp.returns = nilType
                else
                    local returns = {
                        type = "type.list"
                    }
                    local maxReturns = 1
                    for i, ret in ipairs(source.returns) do
                        ret = {table.unpack(ret)}
                        local last = #ret
                        for j = 1, math.huge do
                            if j > maxReturns and not ret[j] then
                                break
                            end
                            local valueType = m.getType(ret[j] or nilType)
                            if j == last and valueType.parent and valueType.parent.type == "type.list" then
                                for k = 2, #valueType.parent do
                                    ret[#ret+1] = valueType.parent[k]
                                end
                            end
                            if returns[j] then
                                if not m.compareTypes(valueType, returns[j]) then
                                    returns[j][#returns[j]+1] = valueType
                                end
                            else
                                returns[j] = {
                                    type = "type.union",
                                    valueType
                                }
                                if i > 1 then
                                    returns[j][#returns[j]+1] = nilType
                                end
                            end
                        end
                        maxReturns = #ret > maxReturns and #ret or maxReturns
                    end
                    for i, ret in ipairs(returns) do
                        if #ret == 1 then
                            returns[i] = ret[1]
                        end
                    end
                    if #returns == 1 then
                        returns = returns[1]
                    end
                    tp.returns = returns
                end
            end
            return tp
        end
    end
    return {
        [1] = infer.type,
        type = "type.name"
    }
end

function m.compareTypes(a, b, mark)
    a = m.normalizeType(a)
    b = m.normalizeType(b)
    if (a.type == "type.union" and #a == 0)
    or (b.type == "type.union" and #b == 0) then
        return false
    end
    if a == b or a[1] == "any" or b[1] == "any" then
        return true
    end
    mark = mark or {}
    if mark[("%p%p"):format(a, b)] then
        return true
    end
    mark[("%p%p"):format(a, b)] = true
    if a.original and b.original and a.original == b.original then
        if mark[a.original] then
            return true
        end
        mark[a.original] = true
    end
    if a.type == "type.union" then
        local allMatch = true
        for _, v in ipairs(guide.getAllValuesInType(a)) do
            if m.options["union-bivariance"] then
                allMatch = false
                if m.compareTypes(v, b, mark) then
                    return true
                end
            elseif not m.compareTypes(v, b, mark) then
                allMatch = false
                break
            end
        end
        if allMatch then
            return true
        end
    end
    if b.type == "type.name" then
        if a.type == "type.name" then
            if rbxlibs.ClassNames[b[1]] then
                if a[1] == "Instance" or rbxlibs.isA(a[1], b[1]) then
                    return true
                end
            end
            if (b[1] == "EnumItem" and a[1]:sub(1, 5) == "Enum.")
            or (a[1] == "EnumItem" and b[1]:sub(1, 5) == "Enum.") then
                return true
            end
            return a[1] == b[1]
        end
        if (b[1] == "function" and a.type == "type.function")
        or (b[1] == "table" and (a.type == "type.table" or a.type == "type.meta")) then
            return true
        end
    elseif b.type == "type.union" then
        local values = guide.getAllValuesInType(b)
        if a.type == "type.union" then
            for _, avalue in ipairs(guide.getAllValuesInType(a)) do
                for _, bvalue in ipairs(values) do
                    if m.compareTypes(avalue, bvalue, mark) then
                        goto CONTINUE
                    end
                end
                do
                    return false
                end
                ::CONTINUE::
            end
            return true
        else
            for _, v in ipairs(values) do
                if m.compareTypes(a, v, mark) then
                    return true
                end
            end
        end
    elseif b.type == "type.inter" then

    elseif b.type == "type.list" then
        local a = a.type == "type.list" and a or {a}
        local varargsA, varargsB = nil, nil
        for i = 1, guide.getTypeCount(b) do
            if varargsA and varargsB then
                break
            end
            local arg = a[i]
            if arg and arg.type == "type.variadic" then
                varargsA = arg.value
            end
            arg = varargsA or arg
            if not arg then
                if i > #b or b.funcargs then
                    break
                end
                arg = nilType
            end
            local other = b[i]
            if other and other.type == "type.variadic" then
                varargsB = other.value
            end
            other = varargsB or other
            if not other then
                return false
            end
            if b.funcargs then
                other, arg = arg, other
            end
            if not m.compareTypes(arg, other, mark) then
                return false
            end
        end
        return true
    elseif b.type == "type.variadic" then
        if a.type == "type.list" then
            for _, value in ipairs(a) do
                if not m.compareTypes(value, b, mark) then
                    return false
                end
            end
            return true
        else
            return m.compareTypes(a.type == "type.variadic" and a.value or a, b.value, mark)
        end
    elseif b.type == "type.function" then
        if a.type == "type.name" and a[1] == "function" then
            return true
        end
        if a.type == "type.function" then
            if a.args then
                if #a.args > guide.getTypeCount(b.args) then
                    return false
                end
                if not m.compareTypes(a.args, b.args, mark) then
                    return false
                end
            end
            if a.returns and not m.compareTypes(a.returns, b.returns, mark) then
                return false
            end
            return true
        end
    elseif b.type == "type.table" then
        if a.type == "type.name" and a[1] == "table" then
            return true
        end
        if a.type == "type.table" then
            local indexType = nil
            local fieldsChecked = {}
            for _, field in ipairs(b) do
                if field.type == "type.field" then
                    local otherField = m.searchFieldType(a, field.key[1], stringType)
                    if not otherField then
                        if not m.hasTypeName(field.value, "nil") then
                            return false
                        end
                        goto CONTINUE
                    end
                    if not m.compareTypes(otherField, field.value, mark) then
                        return false
                    end
                    fieldsChecked[field.key[1]] = true
                elseif field.type == "type.index" then
                    indexType = field
                end
                ::CONTINUE::
            end
            for _, field in ipairs(a) do
                if field.type == "type.field" then
                    if not fieldsChecked[field.key[1]] then
                        if indexType then
                            if not m.compareTypes(stringType, indexType.key, mark)
                            or not m.compareTypes(field.value, indexType.value, mark) then
                                return false
                            end
                        elseif not m.options["ignore-extra-fields"] then
                            return false
                        end
                    end
                elseif field.type == "type.index" then
                    if indexType then
                        if not m.compareTypes(field.key, indexType.key, mark)
                        or not m.compareTypes(field.value, indexType.value, mark) then
                            return false
                        end
                    elseif not m.options["ignore-extra-fields"] then
                        return false
                    end
                end
            end
            return true
        end
    elseif b.type == "type.meta" then
        if a.type == "type.name" and a[1] == "table" then
            return true
        end
        if a.type == "type.meta" then
            return m.compareTypes(a[1], b[1], mark) and m.compareTypes(a[2], b[2], mark)
        end
    end
    return false
end

function m.searchFieldType(tp, key, index)
    tp = m.normalizeType(tp)
    if tp.type == "type.union" then
        local union = {
            type = "type.union"
        }
        for _, value in ipairs(guide.getAllValuesInType(tp)) do
            local field = m.searchFieldType(value, key, index)
            if not field then
                if m.options["union-bivariance"] then
                    goto CONTINUE
                end
                union = nil
                break
            end
            if not m.compareTypes(field, union) then
                union[#union+1] = field
            end
            ::CONTINUE::
        end
        if union and #union > 0 then
            if #union == 1 then
                union = union[1]
            end
            return union
        end
    elseif tp.type == "type.inter" then
        for _, value in ipairs(guide.getAllValuesInType(tp)) do
            local field = m.searchFieldType(value, key, index)
            if field then
                return field
            end
        end
    end
    if tp.type == "type.meta" then
        local field = m.searchFieldType(tp[1], key, index)
        if field then
            return field
        end
        local __index = m.searchFieldType(tp[2], "__index")
        if __index then
            local metaField = m.searchFieldType(__index, key, index)
            if metaField then
                return metaField
            end
        end
    end
    local indexType = nil
    if tp.type == "type.name" then
        if tp[1] == "table" then
            return anyType
        end
        local ret = guide.eachChildOfLibrary(tp, function (child)
            if child.type == "type.index" and key then
                indexType = child
            elseif child.name == key then
                return child
            end
        end)
        if ret then
            return ret.value
        end
    end
    if tp.type == "type.table" then
        for _, field in ipairs(tp) do
            if field.type == "type.field" and field.key[1] == key then
                return field.value
            elseif field.type == "type.index" then
                indexType = field
            end
        end
    end
    if index then
        if indexType then
            if m.compareTypes(index, indexType.key) then
                return indexType.value
            end
        elseif not key and m.compareTypes(index, stringType) then
            return anyType
        end
        if m.hasTypeName(index, "any") or m.hasTypeName(tp, "any") then
            return anyType
        end
    end
    return nil
end

function m.hasTypeName(tp, name)
    tp = m.normalizeType(tp)
    if tp.type == "type.name" and tp[1] == name then
        return true
    end
    if tp.type == "type.union" then
        for _, value in ipairs(guide.getAllValuesInType(tp)) do
            if m.hasTypeName(m.normalizeType(value), name) then
                return true
            end
        end
    end
    return false
end

function m.getArgCount(args)
    local count = 0
    local optionals = 0
    for _, arg in ipairs(args) do
        if arg.type ~= "type.variadic" then
            if m.hasTypeName(m.normalizeType(arg), "nil")
            or (arg.type == "type.name" and arg[1] == "any") then
                optionals = optionals + 1
            else
                count = count + 1 + optionals
                optionals = 0
            end
        end
    end
    return count
end

local function checkCallFunction(func, call, pushResult)
    local argCount = m.getArgCount(func.args)
    if not call.args  then
        if argCount > 0 then
            pushResult {
                start = call.start,
                finish = call.finish,
                message = lang.script('TYPE_ARGUMENT_COUNT', argCount, "none"),
                argChecked = 0
            }
            return false
        end
        return true
    end
    local callArgs = {table.unpack(call.args)}
    local argChecked = 0
    local tuple = nil
    local varargs = nil
    for i = 1, guide.getTypeCount(func.args) do
        local arg = func.args[i]
        if arg and arg.type == "type.variadic" then
            varargs = arg.value
        end
        local argType = varargs or arg
        if not argType then
            break
        end
        local other = callArgs[i]
        if not other then
            break
        end
        argChecked = argChecked + 1
        local otherType = m.getType(other)
        if otherType.parent and i == #call.args then
            if otherType.parent.type == "type.list" then
                tuple = other
                for j = 2, #otherType.parent do
                    if otherType.parent[j].type == "type.variadic" then
                        for _ = i + j - 1, #func.args do
                            callArgs[#callArgs+1] = otherType.parent[j].value
                        end
                    else
                        if #callArgs == #func.args then
                            break
                        end
                        callArgs[#callArgs+1] = otherType.parent[j]
                    end
                end
            elseif otherType.parent.type == "type.variadic" then
                tuple = other
                for _ = i + 1, #func.args do
                    callArgs[#callArgs+1] = otherType
                end
            end
        end
        if not m.compareTypes(otherType, argType) then
            pushResult {
                start = tuple and tuple.start or other.start,
                finish = tuple and tuple.finish or other.finish,
                message = lang.script('TYPE_INCONVERTIBLE', buildType(otherType), buildType(argType)),
                argChecked = argChecked
            }
            return false
        end
    end
    if #callArgs > argChecked or #callArgs < argCount then
        if #callArgs > argChecked and argChecked ~= argCount then
            pushResult {
                start = call.args.start,
                finish = call.args.finish,
                message = lang.script('TYPE_ARGUMENT_COUNT_OR', argCount, argChecked, #callArgs),
                argChecked = argChecked
            }
        else
            pushResult {
                start = call.args.start,
                finish = call.args.finish,
                message = lang.script('TYPE_ARGUMENT_COUNT', argCount, #callArgs),
                argChecked = argChecked
            }
        end
        return false
    end
    return true
end

local function checkCall(source, pushResult, funcType)
    if not source.node and not funcType then
        return
    end
    if funcType or m.hasTypeAnn(source.node, true) then
        funcType = m.normalizeType(funcType or m.getType(source.node))
        if funcType.type == "type.meta" then
            funcType = m.searchFieldType(funcType[2], "__call") or funcType
        end
        if funcType.type == "type.function" then
            return checkCallFunction(funcType, source, pushResult)
        elseif funcType.type == "type.inter" or (m.options["union-bivariance"] and funcType.type == "type.union") then
            local funcs = {}
            for _, value in ipairs(guide.getAllValuesInType(funcType)) do
                value = m.normalizeType(value)
                if value.type == "type.function" then
                    funcs[#funcs+1] = value
                end
            end
            if #funcs > 0 then
                local results = {}
                local function push(result)
                    results[#results+1] = result
                end
                for _, v in ipairs(funcs) do
                    if checkCallFunction(v, source, push) then
                        return true
                    end
                end
                if #results > 0 then
                    table.sort(results, function(a, b)
                        return a.argChecked > b.argChecked
                    end)
                    results[1].message = results[1].message .. string.format(" Others %d overloads failed.", #results - 1)
                    pushResult(results[1])
                end
                return
            end
        end
        if not m.hasTypeName(funcType, "any") and not m.hasTypeName(funcType, "function") then
            pushResult {
                start = source.start,
                finish = source.finish,
                message = lang.script('TYPE_CANNOT_CALL', buildType(funcType))
            }
        end
    end
end

local function checkSetLocal(source, pushResult)
    if not source.value or not source.loc or not source.loc.typeAnn then
        return
    end
    local valueType = m.getType(source.value)
    local locType = source.loc.typeAnn.value
    if not m.compareTypes(valueType, locType) then
        pushResult {
            start = source.start,
            finish = source.value.finish,
            message = lang.script('TYPE_INCONVERTIBLE', buildType(valueType), buildType(locType)),
        }
    end
end

local function checkLocal(source, pushResult)
    if not source.value or not source.typeAnn then
        return
    end
    local typeAnn = source.typeAnn
    source.typeAnn = nil
    local valueType = m.getType(source.value)
    source.typeAnn = typeAnn
    if not m.compareTypes(valueType, typeAnn.value) then
        pushResult {
            start = source.value.start,
            finish = source.value.finish,
            message = lang.script('TYPE_INCONVERTIBLE', buildType(valueType), buildType(typeAnn.value))
        }
    end
end

local function checkGetField(source, pushResult, checkNoType)
    if not source.node then
        return
    end
    if not source.field and not source.method then
        return
    end
    local field = source.field or source.method
    local key = guide.getKeyName(field)
    if m.hasTypeAnn(source.node) then
        local nodeType = m.getType(source.node)
        local fieldType = m.searchFieldType(nodeType, key, stringType)
        if not fieldType then
            pushResult {
                start = field.start,
                finish = field.finish,
                message = lang.script('TYPE_FIELD_NOT_FOUND', key, buildType(nodeType))
            }
        else
            if fieldType.override then
                fieldType = fieldType.override
            end
            return fieldType
        end
    elseif m.strict and checkNoType then
        -- if not m.checkDefinition(source.node) then
        --     return
        -- end
        -- local nodeType = m.getType(source.node)
        -- if m.hasTypeName(nodeType, "table") or m.hasTypeName(nodeType, "any") then
        --     return
        -- end
        -- local fields = vm.getFields(source.node, 0, inferOptions)
        -- for _, field in ipairs(fields) do
        --     if guide.getKeyType(field) == "string" and guide.getKeyName(field) == key then
        --         return
        --     end
        -- end
        -- pushResult {
        --     start = field.start,
        --     finish = field.finish,
        --     message = lang.script('TYPE_FIELD_NOT_FOUND', key, buildType(nodeType))
        -- }
    end
end

local function checkGetIndex(source, pushResult)
    if not source.node or not source.index then
        return
    end
    if m.hasTypeAnn(source.node) then
        local nodeType = m.getType(source.node)
        local key
        if guide.getKeyType(source) == "string" then
            key = guide.getKeyName(source)
        end
        local indexType = m.getType(source.index)
        local fieldType = m.searchFieldType(nodeType, key, indexType)
        if not fieldType then
            pushResult {
                start = source.index.start,
                finish = source.index.finish,
                message = key and lang.script('TYPE_FIELD_NOT_FOUND', key, buildType(nodeType))
                               or lang.script('TYPE_INDEX_NOT_FOUND', buildType(indexType), buildType(nodeType))
            }
        else
            if fieldType.override then
                fieldType = fieldType.override
            end
            return fieldType
        end
    end
end

local function checkSetField(source, fieldType, pushResult)
    if not source.value then
        return
    end
    local field = source.field or source.method or source.index
    if (fieldType.parent and fieldType.parent.readOnly)
    or m.normalizeType(m.getType(source.node)).readOnly then
        pushResult {
            start = field.start,
            finish = field.finish,
            message = lang.script('TYPE_FIELD_READ_ONLY', guide.getKeyName(field))
        }
        return
    end
    local valueType = m.getType(source.value)
    if source.index and isIndexValue(fieldType) and m.compareTypes(valueType, nilType) then
        return
    end
    if not m.compareTypes(valueType, fieldType) then
        pushResult {
            start = source.value.start,
            finish = source.value.finish,
            message = lang.script('TYPE_INCONVERTIBLE', buildType(valueType), buildType(fieldType))
        }
    end
end

local function checkFunction(source, pushResult)
    if not source.returnTypeAnn then
        return
    end
    local returnTypeAnn = source.returnTypeAnn.value
    if not source.returns then
        if not m.compareTypes(nilType, returnTypeAnn) then
            pushResult {
                start = source.keyword[3],
                finish = source.finish,
                message = lang.script('TYPE_INCONVERTIBLE', "nil", buildType(returnTypeAnn))
            }
        end
        return
    end
    for _, ret in ipairs(source.returns) do
        local returnType = #ret == 0 and nilType or nil
        if not returnType then
            returnType = {
                type = "type.list"
            }
            for i, value in ipairs(ret) do
                local valueType = m.getType(value)
                if i == #ret and valueType.parent and valueType.parent.type == "type.list" then
                    for _, v in ipairs(valueType.parent) do
                        returnType[#returnType+1] = v
                    end
                else
                    returnType[#returnType+1] = valueType
                end
            end
            if #returnType == 1 then
                returnType = returnType[1]
            end
        end
        if not m.compareTypes(returnType, returnTypeAnn) then
            pushResult {
                start = ret.start,
                finish = ret.finish,
                message = lang.script('TYPE_INCONVERTIBLE', buildType(returnType), buildType(returnTypeAnn))
            }
        end
    end
end

local function checkBinary(source, pushResult)
    local op = source.op.type
    if op == "and" or op == "or" then
        return
    end
    if m.hasTypeName(m.getType(source[1]), "any")
    or m.hasTypeName(m.getType(source[2]), "any") then
        return
    end
    local results = {}
    local function push(result)
        results[#results+1] = result
    end
    local call = {
        args = source,
        start = source.start,
        finish = source.finish
    }
    local foundMeta = false
    for i = 1, 2 do
        local metamethods = guide.requestMeta(source[i], vm.interface, 0, inferOptions)
        for _, meta in ipairs(metamethods) do
            if guide.binaryMeta[op] == guide.getKeyName(meta) then
                foundMeta = true
                if checkCall(call, push, guide.getObjectValue(meta)) and m.options["union-bivariance"] then
                    return
                end
            end
        end
        if foundMeta then
            break
        end
    end
    if not foundMeta then
        if op == "==" or op == "~=" then
            return
        end
        pushResult {
            start = source.start,
            finish = source.finish,
            message = lang.script("TYPE_BINARY", buildType(m.getType(source[1])), buildType(m.getType(source[2])), op)
        }
    elseif #results > 0 then
        pushResult(results[1])
    end
end

local function checkUnary(source, pushResult)
    local op = source.op.type
    if op == "not" then
        return
    end
    if m.hasTypeName(m.getType(source[1]), "any") then
        return
    end
    local metamethods = guide.requestMeta(source[1], vm.interface, 0, inferOptions)
    for _, meta in ipairs(metamethods) do
        if guide.unaryMeta[op] == guide.getKeyName(meta) then
            return
        end
    end
    pushResult {
        start = source.start,
        finish = source.finish,
        message = lang.script("TYPE_UNARY", buildType(m.getType(source[1])), op)
    }
end

local function getCache(mode)
    local cache = vm.getCache("cache")["typechecking-" .. mode]
    if not cache then
        cache = {
            type = {},
            convert = {},
            normalize = {},
            field = {}
        }
        vm.getCache("cache")["typechecking-" .. mode] = cache
    end
    return cache
end

local function checkTypecheckModeAt(ast, offset)
    if not ast.docs or #ast.docs == 0 then
        m.cache.convert = {}
        return true
    end
    local closestDoc = nil
    local closestRange = math.huge
    for _, doc in ipairs(ast.docs) do
        if doc.type == "doc.typecheck" and doc.range < offset and (offset - doc.range) < closestRange then
            closestDoc = doc
            closestRange = offset - doc.range
        end
    end
    if closestDoc then
        local mode = closestDoc.names[1][1]
        if mode == "nocheck" then
            return false
        elseif mode == "nonstrict" then
            m.strict = false
        elseif mode == "strict" then
            m.strict = true
        else
            m.strict = config.config.typeChecking.mode == "Strict"
        end
    else
        m.strict = config.config.typeChecking.mode == "Strict"
    end
    m.cache = getCache(tostring(m.strict))
    m.cache.convert = {}
    return true
end

function m.init()
    m.strict = config.config.typeChecking.mode == "Strict"
    m.cache = getCache(tostring(m.strict))
    m.options = util.mergeTable(
        util.shallowCopy(define.TypeCheckingOptions),
        config.config.typeChecking.options
    )
end

function m.check(uri)
    local ast = files.getAst(uri)
    if not ast then
        return
    end

    ast = ast.ast
    m.init()

    local results = {}

    local function pushResult(result)
        result.code = "type-checking"
        result.level = define.DiagnosticSeverity.Warning
        results[#results+1] = result
    end

    local skipNodes = {}

    if not config.config.diagnostics.enable then
        undefinedType(uri, pushResult)
        redefinedType(uri, pushResult)
        invalidClassName(uri, pushResult)
    end

    guide.eachSourceType(ast, "setlocal", function (source)
        if checkTypecheckModeAt(ast, source.start) then
            checkSetLocal(source, pushResult)
        end
    end)
    guide.eachSourceType(ast, "local", function (source)
        if checkTypecheckModeAt(ast, source.start) then
            checkLocal(source, pushResult)
        end
    end)
    guide.eachSourceType(ast, "getfield", function (source)
        if skipNodes[source.node] then
            skipNodes[source] = true
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            if not checkGetField(source, pushResult, true) then
                skipNodes[source] = true
            end
        end
    end)
    guide.eachSourceType(ast, "setfield", function (source)
        if skipNodes[source.node] then
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            local field = checkGetField(source, pushResult)
            if field then
                checkSetField(source, field, pushResult)
            end
        end
    end)
    guide.eachSourceType(ast, "getmethod", function (source)
        if skipNodes[source.node] then
            skipNodes[source] = true
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            if not checkGetField(source, pushResult, true) then
                skipNodes[source] = true
            end
        end
    end)
    guide.eachSourceType(ast, "setmethod", function (source)
        if skipNodes[source.node] then
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            local field = checkGetField(source, pushResult)
            if field then
                checkSetField(source, field, pushResult)
            end
        end
    end)
    guide.eachSourceType(ast, "getindex", function (source)
        if skipNodes[source.node] then
            skipNodes[source] = true
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            if not checkGetIndex(source, pushResult) then
                skipNodes[source] = true
            end
        end
    end)
    guide.eachSourceType(ast, "setindex", function (source)
        if skipNodes[source.node] then
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            local field = checkGetIndex(source, pushResult)
            if field then
                checkSetField(source, field, pushResult)
            end
        end
    end)
    guide.eachSourceType(ast, "call", function (source)
        -- if skipNodes[source.node] then
        --     skipNodes[source] = true
        --     return
        -- end
        if source.nocheck then
            return
        end
        if checkTypecheckModeAt(ast, source.start) then
            checkCall(source, pushResult)
        end
    end)
    guide.eachSourceType(ast, "function", function (source)
        if checkTypecheckModeAt(ast, source.start) then
            checkFunction(source, pushResult)
        end
    end)
    guide.eachSourceType(ast, "binary", function (source)
        if checkTypecheckModeAt(ast, source.start) then
            checkBinary(source, pushResult)
        end
    end)
    guide.eachSourceType(ast, "unary", function (source)
        if checkTypecheckModeAt(ast, source.start) then
            checkUnary(source, pushResult)
        end
    end)

    return results
end

return m