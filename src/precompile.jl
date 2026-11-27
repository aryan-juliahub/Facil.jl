using PrecompileTools: @setup_workload, @compile_workload

# Common handler idioms, so a user's first request mostly reuses compiled HttpTypes code.
function sample_handler(req)
    p = path(uri(req))
    q = query(uri(req))
    v = get(headers(req), "x-custom", nothing)
    c = get(headers(req), header.CONTENT_TYPE, nothing)
    if p == "/precompile" && q !== nothing && v !== nothing && c !== nothing
        return Response(StatusCodes.OK, body(req); headers = [header.CONTENT_TYPE => "application/json", "x-id" => "1"])
    elseif p == "/json"
        return Response(StatusCodes.OK, "{}"; headers = [header.CONTENT_TYPE => "application/json"])
    elseif p == "/s"
        return Response(StatusCodes.OK, "s"; headers = ["content-type" => "text/plain", "x-id" => "1"])
    elseif p == "/hi"
        return Response(StatusCodes.OK, "hi")
    elseif p == "/b"
        return Response(StatusCodes.OK, UInt8[0x61]; headers = ["content-type" => "application/octet-stream"])
    elseif p == "/c"
        return Response(StatusCodes.CREATED, "x"; headers = HeaderMap(header.LOCATION => "/c"))
    end
    Response(StatusCodes.NOT_FOUND)
end
sample_text(req) = string(method(req), " ", path(uri(req)))

@setup_workload begin
    @compile_workload begin
        if !libfjl_missing()
            libfjl_handle[] == C_NULL && load_libfjl()
            init_server()
            servers = (Server{typeof(sample_handler)}(sample_handler, "", 0, ServerOptions(), C_NULL, CLOSED, Base.Event()),
                       Server{typeof(sample_text)}(sample_text, "", 0, ServerOptions(), C_NULL, CLOSED, Base.Event()))
            for res in (Response(StatusCodes.OK, "{}"; headers = [header.CONTENT_TYPE => "application/json", "x-id" => "1"]),
                        Response(StatusCodes.OK, UInt8[0x61, 0x62]), Response(StatusCodes.NOT_FOUND), "text", servers...)
                h = @ccall LIBFJL.fjl_http_fake_request()::Ptr{Cvoid}
                try
                    if res isa Server
                        handle(res, h)
                    else
                        read_request(h)
                        respond(h, res)
                        fail(h, 500)
                    end
                finally
                    @ccall LIBFJL.fjl_http_fake_free(h::Ptr{Cvoid})::Cvoid
                end
            end
            for res in (Response(StatusCodes.OK, "{}"; headers = [header.CONTENT_TYPE => "application/json"]), "text", HandlerFailed())
                h = @ccall LIBFJL.fjl_http_fake_request()::Ptr{Cvoid}
                try
                    put_result!(UInt64(0), res)
                    on_resume(h, UInt64(0))
                finally
                    @ccall LIBFJL.fjl_http_fake_free(h::Ptr{Cvoid})::Cvoid
                end
            end
            precompile(check_keywords, (Any,))
            precompile(compress_options, (Bool,))
            precompile(start_server, (Any, String, Int, Dict{Symbol,Any}))
            precompile(on_resume, (Ptr{Cvoid}, UInt64))
            precompile(on_drop, (UInt64,))
            precompile(run_handler, (Server, Request{String}, Ptr{Cvoid}, UInt64))
            precompile(handle_async, (Server, Ptr{Cvoid}, Request{String}))
            precompile(timer_fire, (Ptr{Ptr{Cvoid}}, Cint))
            precompile(sleep, (Float64,))
            precompile(sleep_until, (UInt64,))
            precompile(on_request, (Ptr{Cvoid},))
            precompile(on_closed, (Ptr{Cvoid},))
            precompile(on_release, (Ptr{Cvoid},))
            precompile(body_released, (Ptr{Cvoid},))
            precompile(on_body_headers, (Ptr{Cvoid}, Int64, Ptr{BodyPlanC}))
            precompile(on_body_data, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{UInt8}, Csize_t))
            precompile(on_body_abort, (Ptr{Cvoid}, Int32))
            precompile(read_request, (Server, Ptr{Cvoid}))
            precompile(complete, (PendingBody, Ptr{Cvoid}, BodyInfoC))
            precompile(drain_at_exit, (Int,))
            precompile(on_stream_gone, (Ptr{Cvoid},))
            precompile(on_stream_drain, (Int, Ptr{Cvoid}))
            precompile(on_sse_close, (Ptr{Cvoid},))
            precompile(negotiate, (String, Vector{Symbol}))
            precompile(compress_response, (Request{String}, Response{String}, CompressOptions))
            precompile(respond, (Ptr{Cvoid}, Response{FileBody}))
            precompile(log_error, (String, ErrorException, Vector{Union{Ptr{Nothing},Base.InterpreterIP}}))
        end
    end
end
