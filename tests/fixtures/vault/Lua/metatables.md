# Metatables

A metatable changes how a table behaves: `__index` supplies a fallback for missing keys, which is how objects and inheritance are built, `__newindex` intercepts assignments, and `__call` makes a table callable. Set it with setmetatable and read it with getmetatable.
