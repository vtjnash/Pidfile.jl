using Documenter
using Pidfile

# The DOCSARGS environment variable can be used to pass additional arguments to make.jl.
# This is useful on CI, if you need to change the behavior of the build slightly but you
# can not change the .travis.yml or make.jl scripts any more (e.g. for a tag build).
if haskey(ENV, "DOCSARGS")
    for arg in split(ENV["DOCSARGS"])
        (arg in ARGS) || push!(ARGS, arg)
    end
end

makedocs(
    modules = [Pidfile],
    format = Documenter.HTML(
        prettyurls = true,
        canonical = "https://vtjnash.github.io/Pidfile.jl/",
    ),
    sitename = "Pidfile.jl",
    pages = [
        "Home" => "index.md",
    ],
    linkcheck = true,
    doctest = true,
)

#deploydocs(
#    repo = "github.com/vtjnash/Pidfile.jl.git",
#    target = "build",
#    push_preview = true,
#)
