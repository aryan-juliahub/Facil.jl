function _pattern_method(m)
    m === Methods.GET && return "GET"
    m === Methods.POST && return "POST"
    return "CUSTOM"
end

@testset "patterns::method_constants" begin
    for name in ("GET", "POST", "CUSTOM")
        m = HttpMethod(codeunits(name))
        @test _pattern_method(m) == name
        @test get(Dict(Methods.GET => "GET", Methods.POST => "POST"), m, "CUSTOM") == name
    end
    @test Methods.GET === Methods.GET
    @test HttpMethod("CUSTOM") === HttpMethod("CUSTOM")
end

@testset "patterns::status_code_constants" begin
    for code in (100, 200, 301, 404, 500, 599)
        s = StatusCode(code)
        matched = s === StatusCodes.CONTINUE ? 100 :
                  s === StatusCodes.OK ? 200 :
                  s === StatusCodes.MOVED_PERMANENTLY ? 301 :
                  s === StatusCodes.NOT_FOUND ? 404 :
                  s === StatusCodes.INTERNAL_SERVER_ERROR ? 500 : 599
        @test matched == code
    end
    @test StatusCodes.OK === StatusCodes.OK
end

@testset "patterns::version_constants" begin
    for (v, expected) in ((Versions.HTTP_09, "HTTP/0.9"), (Versions.HTTP_10, "HTTP/1.0"),
                          (Versions.HTTP_11, "HTTP/1.1"), (Versions.HTTP_2, "HTTP/2.0"),
                          (Versions.HTTP_3, "HTTP/3.0"))
        matched = v === Versions.HTTP_09 ? "HTTP/0.9" :
                  v === Versions.HTTP_10 ? "HTTP/1.0" :
                  v === Versions.HTTP_11 ? "HTTP/1.1" :
                  v === Versions.HTTP_2 ? "HTTP/2.0" :
                  v === Versions.HTTP_3 ? "HTTP/3.0" : error("unrecognized version")
        @test matched == expected
    end
    @test Versions.HTTP_11 === Versions.HTTP_11
end

@testset "patterns::header_name_constants" begin
    for name in ("accept", "content-type", "host", "x-custom")
        for input in (name, uppercase(name))
            h = HeaderName(codeunits(input))
            matched = h === header.ACCEPT ? "accept" :
                      h === header.CONTENT_TYPE ? "content-type" :
                      h === header.HOST ? "host" : "x-custom"
            @test matched == name
        end
    end
    @test header.CONTENT_TYPE === header.CONTENT_TYPE
end
