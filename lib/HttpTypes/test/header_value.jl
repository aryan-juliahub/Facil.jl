for (rname, T) in (("from_u16", UInt16), ("from_i16", Int16), ("from_u32", UInt32), ("from_i32", Int32),
                   ("from_u64", UInt64), ("from_i64", Int64), ("from_usize", UInt), ("from_isize", Int))
    @testset "value::$rname" begin
        n = T(55)
        @test HeaderValue(n) == string(n)
        n = typemax(T)
        @test HeaderValue(n) == string(n)
    end
end

@testset "value::it_can_insert_header_name_as_header_value" begin
    map = HeaderMap()
    insert!(map, header.UPGRADE, HeaderValue(header.SEC_WEBSOCKET_PROTOCOL))
    insert!(map, header.ACCEPT, HeaderValue(HeaderName(b"hello-world")))
    @test map[header.UPGRADE] == HeaderValue(b"sec-websocket-protocol")
    @test map[header.ACCEPT] == HeaderValue(b"hello-world")
end

@testset "value::it_converts_using_try_from" begin
    @test HeaderValue(header.UPGRADE) == HeaderValue(b"upgrade")
    @test convert(HeaderValue, header.UPGRADE) == "upgrade"
end

@testset "value::test_try_from" begin
    @test_throws InvalidHeaderValue HeaderValue([0x7f])
end

@testset "value::test_string_constructors_reject_non_ascii" begin
    value = "hello é"
    @test_throws InvalidHeaderValue HeaderValue(value)
    @test tryparse(HeaderValue, value) === nothing
    @test tryparse(HeaderValue, SubString(value, 1)) === nothing
    @test_throws InvalidHeaderValue parse(HeaderValue, value)
end

@testset "value::test_byte_constructors_allow_opaque_bytes_but_reject_del" begin
    @test HeaderValue(b"hello\xff") isa HeaderValue
    @test HeaderValue(view(Vector{UInt8}(b"hello\xff"), 1:6)) isa HeaderValue
    @test HeaderValue(Vector{UInt8}(b"hello\xff")) isa HeaderValue
    @test_throws InvalidHeaderValue HeaderValue(b"hello\x7f")
end

@testset "value::test_string_and_byte_constructors_allow_horizontal_tab" begin
    @test HeaderValue("hello\tworld") isa HeaderValue
    @test HeaderValue(b"hello\tworld") isa HeaderValue
end

@testset "value::test_static_constructor_rejects_non_ascii" begin
    @test_throws InvalidHeaderValue from_static(HeaderValue, "hello é")
    @test_throws LoadError @eval hv"hello é"
end

@testset "value::test_debug" begin
    cases = (("hello", "hv\"hello\""),
        ("hello \"world\"", "hv\"hello \\\"world\\\"\""),
        ("a\\", "hv\"a\\\\\""),
        ("a\tb", "HeaderValue(\"a\\tb\")"),
        ("\xe7\xbfhello", "HeaderValue(codeunits(\"\\xe7\\xbfhello\"))"))
    for (value, expected) in cases
        v = HeaderValue(codeunits(value))
        @test repr(v) == expected
        @test eval(Meta.parse(repr(v))) == v
        @test string(v) == value
    end
    sensitive = set_sensitive(from_static(HeaderValue, "password"), true)
    @test repr(sensitive) == "HeaderValue(<sensitive>)"
    @test !occursin("password", repr([sensitive])) && string(sensitive) == "password"
    @test is_sensitive(sensitive)
end

@testset "value::as_str" begin
    v = HeaderValue(UInt8[0x61, 0xfe, 0x62])
    @test as_str(v) == String(v) == "a\xfeb"
    @test_throws ToStrError to_str(v)
    @test String(hv"text/plain") === as_str(hv"text/plain")
end
