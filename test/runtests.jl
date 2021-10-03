using Pidfile

using Test

using Base.Filesystem: File
using Pidfile: iswindows,
    write_pidfile, parse_pidfile,
    isvalidpid, stale_pidfile,
    tryopen_exclusive, open_exclusive

# helper utilities
struct MemoryFile <: Base.AbstractPipe
    io::IOBuffer
    mtime::Float64
end
Base.pipe_reader(io::MemoryFile) = io.io
Base.Filesystem.mtime(io::MemoryFile) = io.mtime

# set the process umask so we can test the behavior of
# open mask without interference from parent's state
# and create a test environment temp directory
umask(new_mask) = ccall((@static iswindows() ? :_umask : :umask), Cint, (Cint,), new_mask)
@testset "Pidfile.jl" begin
old_umask = umask(0o002)
try
    mktempdir() do dir
        cd(dir) do

# now start tests definitions:

@testset "validpid" begin
    @info "validpid"
    mypid = getpid() % Cuint
    @test isvalidpid(gethostname(), mypid)
    @test isvalidpid("", mypid)
    @test !isvalidpid("", 0 % Cuint)
    @test isvalidpid("NOT" * gethostname(), mypid)
    @test isvalidpid("NOT" * gethostname(), 0 % Cuint)
    @test isvalidpid("NOT" * gethostname(), -1 % Cuint)
    if !iswindows()
        @test isvalidpid("", 1 % Cuint)
        @test !isvalidpid("", -1 % Cuint)
        @test !isvalidpid("", -mypid)
    end
end

@testset "write_pidfile" begin
    @info "write_pidfile"
    buf = IOBuffer()
    pid, host, age = 0, "", 123
    pid2, host2, age2 = parse_pidfile(MemoryFile(seekstart(buf), time() - age))
    @test pid == pid2
    @test host == host2
    @test age ≈ age2 atol=5

    host = " host\r\n"
    write(buf, "-1 $host")
    pid2, host2, age2 = parse_pidfile(MemoryFile(seekstart(buf), time() - age))
    @test pid == pid2
    @test host == host2
    @test age ≈ age2 atol=5
    truncate(seekstart(buf), 0)

    pid, host = getpid(), gethostname()
    write_pidfile(buf, pid)
    @test read(seekstart(buf), String) == "$pid $host"
    pid2, host2, age2 = parse_pidfile(MemoryFile(seekstart(buf), time() - age))
    @test pid == pid2
    @test host == host2
    @test age ≈ age2 atol=5
    truncate(seekstart(buf), 0)

    @testset "parse_pidfile" begin
        age = 0
        @test parse_pidfile("nonexist") === (Cuint(0), "", 0.0)
        open(io -> write_pidfile(io, pid), "pidfile", "w")
        pid2, host2, age2 = parse_pidfile("pidfile")
        @test pid == pid2
        @test host == host2
        @test age ≈ age2 atol=10
        rm("pidfile")
    end
end

@testset "open_exclusive" begin
    @info "open_exclusive"
    f = open_exclusive("pidfile")::File
    try
        # check that f is open and read-writable
        @test isfile("pidfile")
        @test filemode("pidfile") & 0o777 == 0o444
        @test filemode(f) & 0o777 == 0o444
        @test filesize(f) == 0
        @test write(f, "a") == 1
        @test filesize(f) == 1
        @test read(seekstart(f), String) == "a"
        chmod("pidfile", 0o600)
        @test filemode(f) & 0o777 == (iswindows() ? 0o666 : 0o600)
    finally
        close(f)
    end

    # release the pidfile after a short delay
    deleted = false
    rmtask = @async begin
        sleep(3)
        rm("pidfile")
        deleted = true
    end
    @test isfile("pidfile")
    @test !deleted

    # open the pidfile again (should wait for it to disappear first)
    t = @elapsed f2 = open_exclusive("pidfile")::File
    try
        @test deleted
        @test isfile("pidfile")
        @test t > 2
        if t > 6
            println("INFO: watch_file optimization appears to have NOT succeeded")
        end
        @test filemode(f2) & 0o777 == 0o444
        @test filesize(f2) == 0
        @test write(f2, "bc") == 2
        @test read(seekstart(f2), String) == "bc"
        @test filesize(f2) == 2
    finally
        close(f2)
    end
    rm("pidfile")
    wait(rmtask)

    # now test with a long delay and other non-default options
    f = open_exclusive("pidfile", mode = 0o000)::File
    try
        @test filemode(f) & 0o777 == (iswindows() ? 0o444 : 0o000)
    finally
        close(f)
    end
    deleted = false
    rmtask = @async begin
        sleep(8)
        rm("pidfile")
        deleted = true
    end
    @test isfile("pidfile")
    @test !deleted
    # open the pidfile again (should wait for it to disappear first)
    t = @elapsed f2 = open_exclusive("pidfile", mode = 0o777, poll_interval = 1.0)::File
    try
        @test deleted
        @test isfile("pidfile")
        @test filemode(f2) & 0o777 == (iswindows() ? 0o666 : 0o775)
        @test write(f2, "def") == 3
        @test read(seekstart(f2), String) == "def"
        @test t > 7
    finally
        close(f2)
    end
    rm("pidfile")
    wait(rmtask)

    @info "test for wait_for_lock == false cases"
    f = open_exclusive("pidfile", wait_for_lock=false)
    @test isfile("pidfile")
    close(f)
    rm("pidfile")

    f = open_exclusive("pidfile")::File
    deleted = false
    rmtask = @async begin
        sleep(2)
        rm("pidfile")
        deleted = true
    end

    t1 = time()
    @test_throws Pidfile.PidLockFailedError open_exclusive("pidfile", wait_for_lock=false)
    @test time()-t1 ≈ 0 atol=0.3

    sleep(1)
    @test !deleted

    t1 = time()
    @test_throws Pidfile.PidLockFailedError open_exclusive("pidfile", wait_for_lock=false)
    @test time()-t1 ≈ 0 atol=0.3

    sleep(2)
    @test deleted
    t = @elapsed f2 = open_exclusive("pidfile", wait_for_lock=false)::File
    @test isfile("pidfile")
    @test t ≈ 0 atol=0.1
    close(f)
    close(f2)
    rm("pidfile")
end

@testset "open_exclusive: break lock" begin
    @info "open_exclusive: break lock"
    # test for stale_age
    t = @elapsed f = open_exclusive("pidfile", poll_interval=3, stale_age=10)::File
    try
        write_pidfile(f, getpid())
    finally
        close(f)
    end
    @test t < 2
    t = @elapsed f = open_exclusive("pidfile", poll_interval=3, stale_age=1)::File
    close(f)
    @test 20 < t < 50
    rm("pidfile")

    t = @elapsed f = open_exclusive("pidfile", poll_interval=3, stale_age=10)::File
    close(f)
    @test t < 2
    t = @elapsed f = open_exclusive("pidfile", poll_interval=3, stale_age=10)::File
    close(f)
    @test 8 < t < 20
    rm("pidfile")
end

@testset "mkpidlock non-blocking stale lock break" begin
    @info "mkpidlock non-blocking stale lock break"
    # mkpidlock with no waiting
    lockf = mkpidlock("pidfile-2", wait_for_lock=false)

    sleep(1)
    t = @elapsed @test_throws Pidfile.PidLockFailedError mkpidlock("pidfile-2", wait_for_lock=false, stale_age=1, poll_interval=1)
    @test t ≈ 0 atol=0.1

    sleep(10)
    t = @elapsed mkpidlock("pidfile-2", wait_for_lock=false, stale_age=.1, poll_interval=1)
    @test t ≈ 0 atol=0.3
end
            
@testset "mkpidlock" begin
    @info "mkpidlock"
    lockf = mkpidlock("pidfile")
    waittask = @async begin
        sleep(3)
        cd(homedir()) do
            return close(lockf)
        end
    end

    # mkpidlock with no waiting
    t = @elapsed @test_throws Pidfile.PidLockFailedError mkpidlock("pidfile", wait_for_lock=false)
    @test t ≈ 0 atol=0.1

    t = @elapsed lockf1 = mkpidlock("pidfile")
    @test t > 2
    @test istaskdone(waittask) && fetch(waittask)
    @test !close(lockf)
    finalize(lockf1)
    t = @elapsed lockf2 = mkpidlock("pidfile")
    @test t < 2
    @test !close(lockf1)

    # test manual breakage of the lock
    # is correctly handled
    if iswindows()
        mv("pidfile", "xpidfile")
    else
        rm("pidfile")
    end
    t = @elapsed lockf3 = mkpidlock("pidfile")
    @test t < 2
    @test isopen(lockf2.fd)
    @test !close(lockf2)
    @test !isopen(lockf2.fd)
    @test isfile("pidfile")
    @test close(lockf3)
    @test !isfile("pidfile")
    if iswindows()
        rm("xpidfile")
    end

    # Just for coverage's sake, run a test with do-block syntax
    lock_times = Float64[]
    t_loop = @async begin
        for idx in 1:100
            t = @elapsed mkpidlock("do_block_pidfile") do
            end
            sleep(0.01)
            push!(lock_times, t)
        end
    end
    mkpidlock("do_block_pidfile") do
        sleep(3)
    end
    wait(t_loop)
    @test maximum(lock_times) > 2
    @test minimum(lock_times) < 1
end

end; end # cd(tempdir)
finally
    umask(old_umask)
end; end # testset
