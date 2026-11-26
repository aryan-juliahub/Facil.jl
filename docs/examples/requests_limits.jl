using Facil

serve("127.0.0.1", 8080;
      max_header_size = 8 * 1024,      # 431 above this
      max_body_size = 1024 * 1024,     # 413 above this, whatever before_body says
      body_in_memory = 64 * 1024,      # 413 above this for buffered bodies
      header_timeout = 10,             # 408 when the head takes longer
      timeout = 15) do req             # idle keep-alive connections are closed
    Response(StatusCodes.OK, "$(sizeof(body(req))) bytes\n")
end
