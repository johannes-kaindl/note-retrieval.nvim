---
tags: [lua, programming]
---
# Closures

A function in Lua remembers the local variables that were in scope where it was written. A counter is made by returning a function that increments an upvalue; each call of the maker creates a fresh upvalue, so two counters do not share state. Closures are the usual way to keep a value private in a module without a class.

See [[Lua/metatables]] for the other tool of encapsulation.
