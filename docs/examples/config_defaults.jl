using Facil

# Every keyword of `serve` and `serve!`, written out at its default value.
serve(req -> Response(StatusCodes.OK, "ok"), "127.0.0.1", 8080;
      inline = false,
      reactors = 1,
      max_header_size = 32 * 1024,
      max_body_size = 50 * 1024 * 1024,
      body_in_memory = 16 * 1024 * 1024,
      timeout = 40,
      header_timeout = 30,
      max_pending_output = 16 * 1024 * 1024,
      before_body = head -> Buffer(),
      compress = false,
      public_folder = nothing,
      tls = nothing,
      shutdown_grace = 10,
      verbose = false,
      gc_headroom = 0)
