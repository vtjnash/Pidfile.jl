__precompile__()
module Pidfile


export mkpidlock

using Base:
    IOError, UV_EEXIST, UV_ESRCH,
    Process

using Base.Filesystem:
    File, open, JL_O_CREAT, JL_O_RDWR, JL_O_RDONLY, JL_O_EXCL,
    samefile

using FileWatching: watch_file
using Base.Sys: iswindows

"""
    mkpidlock(at::String, [pid::Cint, proc::Process]; kwopts...)

Create a pidfile lock for the path "at" for the current process
or the process identified by pid or proc.

Optional keyword arguments:
 - mode: file access mode (modified by the process umask). Defaults to world-readable.
 - poll_interval: Specify the maximum time to between attempts (if watch_file doesn't work)
 - stale_age: Delete an existing pidfile (ignoring the lock) if its mtime is older than this.
     The file won't be deleted until 25x longer than this if the pid in the file appears that it may be valid.
     By default this is disabled (stale_age = 0), but a typical recommended value would be about 3-5x an
     estimated normal completion time.
"""
function mkpidlock end


mutable struct LockMonitor
    path::String
    fd::File

    global function mkpidlock(at::String, pid::Cint; kwopts...)
        local lock
        at = abspath(at)
        fd = open_exclusive(at; kwopts...)
        try
            write_pidfile(fd, pid)
            lock = new(at, fd)
            finalizer(close, lock)
        catch ex
            close(fd)
            rm(at)
            rethrow(ex)
        end
        return lock
    end
end

mkpidlock(at::String; kwopts...) = mkpidlock(at, getpid(); kwopts...)

# TODO: enable this when we update libuv
#Base.getpid(proc::Process) = ccall(:uv_process_get_pid, Cint, (Ptr{Void},), proc.handle)
#function mkpidlock(at::String, proc::Process; kwopts...)
#    lock = mkpidlock(at, getpid(proc))
#    @schedule begin
#        wait(proc)
#        close(lock)
#    end
#    return lock
#end


"""
    write_pidfile(io, pid)

Write our pidfile format to an open IO descriptor.
"""
function write_pidfile(io::IO, pid::Cint)
    print(io, "$pid $(gethostname())")
end

"""
    parse_pidfile(file::Union{IO, String}) => (pid, hostname, age)

Attempt to parse our pidfile format,
replaced an element with (0, "", 0.0), respectively, for any read that failed.
"""
function parse_pidfile(io::IO)
    fields = split(read(io, String), ' ', limit = 2)
    pid = tryparse(Cuint, fields[1])
    pid === nothing && (pid = Cuint(0))
    hostname = (length(fields) == 2) ? fields[2] : ""
    when = mtime(io)
    age = time() - when
    return (pid, hostname, age)
end

function parse_pidfile(path::String)
    try
        existing = open(path, JL_O_RDONLY)
        try
            return parse_pidfile(existing)
        finally
            close(existing)
        end
    catch ex
        isa(ex, EOFError) || isa(ex, IOError) || rethrow(ex)
        return (Cuint(0), "", 0.0)
    end
end

"""
    isvalidpid(hostname::String, pid::Cuint) :: Bool

Attempt to conservatively estimate whether pid is a valid process id.
"""
function isvalidpid(hostname::AbstractString, pid::Cuint)
    # can't inspect remote hosts
    (hostname == "" || hostname == gethostname()) || return true
    # pid < 0 is never valid (must be a parser error or different OS),
    # and would have a completely different meaning when passed to kill
    !iswindows() && pid > typemax(Cint) && return false
    # (similarly for pid 0)
    pid == 0 && return false
    # see if the process id exists by querying kill without sending a signal
    # and checking if it returned ESRCH (no such process)
    return ccall(:uv_kill, Cint, (Cuint, Cint), pid, 0) != UV_ESRCH
end

"""
    stale_pidfile(path::String, stale_age::Real) :: Bool

Helper function for open_exclusive for deciding if a pidfile is stale.
"""
function stale_pidfile(path::String, stale_age::Real)
    pid, hostname, age = parse_pidfile(path)
    if age < -stale_age
        @warn "filesystem time skew detected" path=path
    elseif age > stale_age
        if (age > stale_age * 25) || !isvalidpid(hostname, pid)
            return true
        end
    end
    return false
end

"""
    tryopen_exclusive(path::String, mode::Integer = 0o444) :: Union{Void, File}

Try to create a new file for read-write advisory-exclusive access,
return nothing if it already exists.
"""
function tryopen_exclusive(path::String, mode::Integer = 0o444)
    try
        return open(path, JL_O_RDWR | JL_O_CREAT | JL_O_EXCL, mode)
    catch ex
        (isa(ex, IOError) && ex.code == UV_EEXIST) || rethrow(ex)
    end
    return nothing
end

"""
    open_exclusive(path::String; mode, poll_interval, stale_age) :: File

Create a new a file for read-write advisory-exclusive access,
blocking until it can succeed.

For a description of the keyword arguments, see [`mkpidlock`](@ref).
"""
function open_exclusive(path::String;
        mode::Integer = 0o444 #= read-only =#,
        poll_interval::Real = 10 #= seconds =#,
        stale_age::Real = 0 #= disabled =#)
    # fast-path: just try to open it
    file = tryopen_exclusive(path, mode)
    file === nothing || return file
    @info "waiting for lock on pidfile" path=path
    # fall-back: wait for the lock
    while true
        # start the file-watcher prior to checking for the pidfile existence
        t = @async try
            watch_file(path, poll_interval)
        catch ex
            isa(ex, IOError) || rethrow(ex)
            sleep(poll_interval) # if the watch failed, convert to just doing a sleep
        end
        # now try again to create it
        file = tryopen_exclusive(path, mode)
        file === nothing || return file
        wait(t) # sleep for a bit before trying again
        if stale_age > 0 && stale_pidfile(path, stale_age)
            # if the file seems stale, try to remove it before attempting again
            # set stale_age to zero so we won't attempt again, even if the attempt fails
            stale_age -= stale_age
            @warn "attempting to remove probably stale pidfile" path=path
            try
                rm(path)
            catch ex
                isa(ex, IOError) || rethrow(ex)
            end
        end
    end
end

"""
    close(lock::LockMonitor)

Release a pidfile lock.
"""
function Base.close(lock::LockMonitor)
    isopen(lock.fd) || return false
    havelock = samefile(stat(lock.fd), stat(lock.path))
    close(lock.fd)
    if havelock # try not to delete someone else's lock
        rm(lock.path)
    end
    return havelock
end

end # module
