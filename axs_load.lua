-- axs_load.lua — 在厂商 EQE 的 mediaserverd Lua 控制台里加载 AxsLevel.dylib（v2）
-- 用法：
--   terminal:      eqe core
--   core# 提示符:  dofile("/var/jb/Library/AxsEQ/axs_load.lua")
-- 注意：控制台只回显"表达式返回值"，不显示 print，所以这里 return 字符串。
--
-- v2 关键：先校验 axs_version()。
--   dlopen 对同一路径有镜像缓存 —— 你重新编译并 cp 覆盖了 AxsLevel.dylib，
--   但只要 mediaserverd 没重启，ffi.load 拿到的还是上一次的旧镜像，新代码根本没跑。
--   v1 没有版本号，只能靠"现象没变"去猜；v2 直接把这件事变成一行可见的报错。

local WANT_VERSION = "axs-eq-2.0"

local out = {}
local function L(s) out[#out+1] = tostring(s) end

-- LuaJIT 里 ffi 调用的返回值是 cdata，直接 tostring 会得到 "cdata<int>: 0x..."
local function num(x)
    local ok, v = pcall(tonumber, x)
    if ok and v ~= nil then return v end
    return x
end

-- 1) 找 cffi（厂商自带模块叫 cffi；ffi 加载失败）
local ffi
for _, n in ipairs({ "ffi", "cffi" }) do
    local ok, m = pcall(require, n)
    if ok and m then ffi = m break end
end
if not ffi then return "没有 cffi 模块" end

-- 2) cdef。重复 dofile 时 LuaJIT 会报 redefinition，属于正常，不当失败处理；
--    真出错的话下面 h.axs_start() 会取到 nil，同样能看见。
local cdefErr = nil
local okc, errc = pcall(function() ffi.cdef[[
const char *axs_version(void);
int         axs_status(void);
int         axs_start(void);
int         axs_stop(void);
long        axs_frames(void);
long        axs_calls(void);
]] end)
if not okc then cdefErr = tostring(errc) end

-- 3) 依次尝试候选路径（arm64e ABI v2 那个优先）
local h, used, errs = nil, nil, {}
for _, p in ipairs({
    "/var/jb/Library/AxsEQ/AxsLevel.dylib",
    "/var/jb/com.r333d.eqe/AxsLevel.dylib",
}) do
    local ok, res = pcall(function() return ffi.load(p) end)
    if ok and res then h = res used = p break end
    errs[#errs+1] = p .. ": " .. tostring(res)
end
if not h then
    return "dylib 加载失败（多为架构不符：mediaserverd 需要 arm64e/PAC）| " ..
           table.concat(errs, " | ")
end

-- 4) 版本校验：抓 dlopen 镜像缓存
local gotv = "?"
local okv, v = pcall(function() return ffi.string(h.axs_version()) end)
if okv and v then gotv = v end

if gotv ~= WANT_VERSION then
    L("实际加载了 " .. used)
    L("版本 = " .. tostring(gotv) .. "，期望 " .. WANT_VERSION)
    L("★ mediaserverd 仍持有旧镜像（dlopen 按路径缓存），新编的 dylib 没生效")
    L("  解决：换成新文件名（AxsLevel_2.dylib + 改本脚本路径），或 respring/重启进程")
    return table.concat(out, " | ")
end

-- 5) 启动
local okr, ret = pcall(function() return h.axs_start() end)
if not okr then return "axs_start 调用异常: " .. tostring(ret) end
ret = num(ret)

local MEANING = "1=成功 0=已在跑 -10=找不到MSHookFunction -11=找不到AudioUnitRender " ..
                "-12=MSHookFunction没回填原函数 -20=并发start -30=端口没起来(钩子仍装上)"

local st = num(h.axs_status()) or -1
local bits = {}
if st % 2 >= 1 then bits[#bits+1] = "钩子" end
if math.floor(st / 2) % 2 >= 1 then bits[#bits+1] = "端口" end
if math.floor(st / 4) % 2 >= 1 then bits[#bits+1] = "写文件" end
if math.floor(st / 8) % 2 >= 1 then bits[#bits+1] = "曾丢帧" end

L("loaded " .. used)
L("start=" .. tostring(ret) .. "  " .. MEANING)
L("status=" .. tostring(st) .. " [" .. table.concat(bits, "+") .. "]")
L("calls=" .. tostring(num(h.axs_calls())) .. " frames=" .. tostring(num(h.axs_frames())))
if cdefErr then L("(cdef 已存在: " .. cdefErr:sub(1, 60) .. ")") end

if st < 1 then
    L("★ 钩子没装上：先确认 ellekit 在、再确认 dylib 是 arm64e")
else
    L("放几秒歌后再 dofile 本脚本，calls/frames 应涨到几千")
end

return table.concat(out, " | ")
