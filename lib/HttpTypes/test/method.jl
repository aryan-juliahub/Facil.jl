@testset "method::test_method_eq" begin
    @test Methods.GET == Methods.GET
    @test Methods.GET == "GET"
    @test "GET" == Methods.GET
    @test Methods.GET != Methods.POST
end

@testset "method::test_invalid_method" begin
    @test_throws InvalidMethod HttpMethod("")
    @test_throws InvalidMethod HttpMethod(UInt8[])
    @test_throws InvalidMethod HttpMethod([0xc0])
    @test_throws InvalidMethod HttpMethod([0x10])
    @test tryparse(HttpMethod, "") === nothing
    @test tryparse(HttpMethod, UInt8[]) === nothing
    @test tryparse(HttpMethod, [0xc0]) === nothing
    @test tryparse(HttpMethod, [0x10]) === nothing
end

@testset "method::test_is_idempotent" begin
    for m in (Methods.OPTIONS, Methods.GET, Methods.PUT, Methods.DELETE, Methods.HEAD, Methods.TRACE, Methods.QUERY)
        @test is_idempotent(m)
    end
    for m in (Methods.POST, Methods.CONNECT, Methods.PATCH)
        @test !is_idempotent(m)
    end
end

@testset "method::test_extension_method" begin
    @test HttpMethod("WOW") == "WOW"
    @test HttpMethod("wOw!!") == "wOw!!"
    long = "This_is_a_very_long_method.It_is_valid_but_unlikely."
    @test HttpMethod(long) == long
    @test HttpMethod(fill(UInt8('A'), 15)) == HttpMethod("A"^15)
    @test HttpMethod(fill(UInt8('A'), 16)) == HttpMethod("A"^16)
end

@testset "method::test_extension_method_chars" begin
    for c in "!#\$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        @test HttpMethod(string(c)) == string(c)
    end
end

@testset "method::doc examples" begin
    @test Methods.GET == HttpMethod(b"GET")
    @test is_idempotent(Methods.GET)
    @test as_str(Methods.POST) == "POST"
end
