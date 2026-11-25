const SCRATCH_BUF_SIZE = 64
const MAX_NAME = HttpTypes.MAX_HEADER_NAME_LEN

@testset "name::test_parse_standard_headers" begin
    for (i, (k, s)) in enumerate(HttpTypes.STANDARD_HEADER_TABLE)
        std = getfield(header, k)
        @test HeaderName(codeunits(s)) == std
        @test HeaderName(codeunits(s)) === std
        @test HeaderName(codeunits(uppercase(s))) === std
    end
end

@testset "name::test_standard_headers_into_bytes" begin
    for (k, s) in HttpTypes.STANDARD_HEADER_TABLE
        std = getfield(header, k)
        @test as_str(HeaderName(codeunits(s))) == s
        @test HeaderName(codeunits(s)) == std
        @test codeunits(as_str(HeaderName(uppercase(s)))) == codeunits(s)
        @test HeaderName(uppercase(s)) == std
    end
end

@testset "name::test_parse_invalid_headers" begin
    for i in 0:127
        @test_throws InvalidHeaderName HeaderName(fill(0x01, i))
    end
end

@testset "name::test_parse_invalid_long_headers" begin
    for len in (SCRATCH_BUF_SIZE + 1, SCRATCH_BUF_SIZE + 2, 256)
        for index in (0, SCRATCH_BUF_SIZE - 1, SCRATCH_BUF_SIZE, len - 1)
            for invalid in (0x00, UInt8(' '), UInt8('\n'), 0x7f, 0x80, 0xff)
                hdr = fill(UInt8('a'), len)
                hdr[index+1] = invalid
                @test tryparse(HeaderName, hdr) === nothing
            end
        end
    end
end

@testset "name::test_invalid_name_lengths" begin
    @test_throws InvalidHeaderName HeaderName(UInt8[])
    long = "a"^MAX_NAME
    @test from_static(HeaderName, long) == long
    @test tryparse(HeaderName, long) !== nothing
    @test_throws InvalidHeaderName HeaderName("a"^(MAX_NAME + 1))
end

@testset "name::test_static_invalid_name_lengths" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "a"^(MAX_NAME + 1))
end

# HdrName is the crate's borrowed, not-yet-lowercased name. Here that role is
# played by raw bytes: parsing them, or comparing a HeaderName against them.
@testset "name::test_from_hdr_name" begin
    @test HeaderName("vary") === header.VARY
    @test as_str(HeaderName(b"hello-world")) == "hello-world"
    @test as_str(HeaderName(b"Hello-World")) == "hello-world"
end

@testset "name::test_eq_hdr_name" begin
    @test header.VARY == "vary"
    a = HeaderName("vaary")
    @test a != header.VARY
    @test a == "vaary"
    @test a == "VAARY"
    @test header.VARY != "VAARY"
end

@testset "name::test_from_static_std" begin
    @test header.VARY == from_static(HeaderName, "vary")
    @test header.VARY != from_static(HeaderName, "vaary")
    @test hn"vary" === header.VARY
end

@testset "name::test_from_static_std_uppercase" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "Vary")
end

@testset "name::test_from_static_std_symbol" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "vary{}")
end

@testset "name::test_from_static_custom_short" begin
    @test HeaderName("customheader") == from_static(HeaderName, "customheader")
    @test as_str(from_static(HeaderName, "customheader")) == "customheader"
end

@testset "name::test_from_static_custom_short_uppercase" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "custom header")
end

@testset "name::test_from_static_custom_short_symbol" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "CustomHeader")
end

const LONG_NAME = "longer-than-63--thisheaderislongerthansixtythreecharactersandthushandleddifferent"

@testset "name::test_from_static_custom_long" begin
    @test HeaderName(LONG_NAME) == from_static(HeaderName, LONG_NAME)
    @test as_str(from_static(HeaderName, LONG_NAME)) == LONG_NAME
end

@testset "name::test_from_static_custom_long_uppercase" begin
    @test_throws InvalidHeaderName from_static(HeaderName,
        "Longer-Than-63--ThisHeaderIsLongerThanSixtyThreeCharactersAndThusHandledDifferent")
end

@testset "name::test_from_static_custom_long_symbol" begin
    @test_throws InvalidHeaderName from_static(HeaderName,
        "longer-than-63--thisheader{}{}{}{}islongerthansixtythreecharactersandthushandleddifferent")
end

@testset "name::test_from_static_custom_single_char" begin
    @test as_str(from_static(HeaderName, "a")) == "a"
    @test from_static(HeaderName, "a") == HeaderName("a")
end

@testset "name::test_from_static_empty" begin
    @test_throws InvalidHeaderName from_static(HeaderName, "")
end

@testset "name::test_all_tokens" begin
    @test from_static(HeaderName, "!#\$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz") isa HeaderName
end

@testset "name::test_from_lowercase" begin
    for n in (10, 100), b in (0x00, UInt8('A'), 0x01, 0xff)
        @test_throws InvalidHeaderName from_lowercase(HeaderName, fill(b, n))
    end
end

@testset "name::test_from_lowercase_rejects_double_quote" begin
    @test_throws InvalidHeaderName from_lowercase(HeaderName, b"x-evil\"name")
end
