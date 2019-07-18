
-define(FAIL_MSG(Str, Args), ?LOG_ERROR(Str, Args), basho_bench_app:halt_or_kill()).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

-define(VAL_GEN_BLOB_CFG, value_generator_blob_file).
-define(VAL_GEN_SRC_SIZE, value_generator_source_size).
