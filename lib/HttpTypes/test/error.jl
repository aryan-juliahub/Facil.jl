@testset "error::inner_error_is_invalid_status_code" begin
    e = try
        StatusCode(6666)
        nothing
    catch ex
        ex
    end
    @test e !== nothing
    err = HttpTypes.Error(e)
    ie = HttpTypes.get_ref(err)
    @test !(ie isa InvalidHeaderValue)
    @test ie isa InvalidStatusCode
    @test err isa HttpError
end

@testset "error: wrapper behaviour" begin
    for (inner, msg) in ((InvalidMethod(), "invalid HTTP method"),
                         (InvalidStatusCode(), "invalid status code"),
                         (InvalidHeaderName(), "invalid HTTP header name"),
                         (InvalidHeaderValue(), "failed to parse header value"),
                         (MaxSizeReached(), "max size reached"))
        err = HttpTypes.Error(inner)
        @test HttpTypes.get_ref(err) === inner
        @test sprint(showerror, err) == msg
    end
    u = try
        Uri("")
    catch ex
        ex
    end
    @test HttpTypes.get_ref(HttpTypes.Error(u)) isa InvalidUri
    @test sprint(showerror, HttpTypes.Error(u)) == sprint(showerror, u)
    err = HttpTypes.Error(InvalidMethod())
    @test HttpTypes.Error(err) === err
    @test convert(HttpTypes.Error, InvalidStatusCode()) isa HttpTypes.Error
    @test sprint(show, err) == "HttpTypes.Error(InvalidMethod())"
    @test !isdefined(Main, :Error) || Main.Error !== HttpTypes.Error
    @test_throws HttpTypes.Error throw(HttpTypes.Error(InvalidUriParts(InvalidUri(:SchemeMissing))))
end
