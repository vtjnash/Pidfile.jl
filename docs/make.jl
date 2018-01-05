using Documenter
using Pidfile

makedocs(
    modules = [Pidfile],
    format = :html,
    sitename = "Pidfile.jl",
    pages = [
        "Home" => "index.md",
    ],
)
