# Pidfile.jl

```@meta
CurrentModule = Pidfile
```

Documentation for [Pidfile.jl](https://github.com/vtjnash/Pidfile.jl):

A simple utility tool for creating advisory pidfiles (lock files).

## Primary Functions

```@docs
mkpidlock
close
```


## Helper Functions

```@docs
Pidfile.open_exclusive
Pidfile.tryopen_exclusive
Pidfile.write_pidfile
Pidfile.parse_pidfile
Pidfile.stale_pidfile
Pidfile.isvalidpid
```
