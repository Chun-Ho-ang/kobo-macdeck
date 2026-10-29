"""Run the Lua tests without a system Lua: pip install lupa, then python3 tests/run_lua_tests.py"""

import pathlib
import sys

import lupa

here = pathlib.Path(__file__).resolve().parent
lua = lupa.LuaRuntime()

# 先對插件所有檔案做語法檢查
bad = 0
for f in sorted((here.parent / "macdeck.koplugin").rglob("*.lua")):
    ok, err = lua.eval("function(s, n) local f, e = load(s, '@' .. n); return f ~= nil, e end")(f.read_text(), str(f))
    if not ok:
        print("SYNTAX", err)
        bad += 1
print(f"syntax: {'ok' if not bad else f'{bad} file(s) failed'}")

lua.execute("os.exit = function(c) error('exit ' .. tostring(c)) end")
script = here / "test_macdeck.lua"
try:
    lua.execute(script.read_text().replace('debug.getinfo(1, "S").source:match("^@(.*)/")', repr(str(here))))
except lupa.LuaError as e:
    print(e)
    sys.exit(1)
sys.exit(1 if bad else 0)
