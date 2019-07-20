.PHONY: deps

REBAR := rebar3

all: compile
	${REBAR} escriptize

deps:
	${REBAR} deps

compile:
	${REBAR} compile

clean:
	${REBAR} clean

runbench:
	_build/default/bin/basho_bench examples/antidote_pb.config

results:
	Rscript --vanilla priv/summary.r -i tests/current

byte_sec-results:
	Rscript --vanilla priv/summary.r --ylabel1stgraph byte/sec -i tests/current

kbyte_sec-results:
	Rscript --vanilla priv/summary.r --ylabel1stgraph Kbyte/sec -i tests/current

mbyte_sec-results:
	Rscript --vanilla priv/summary.r --ylabel1stgraph Mbyte/sec -i tests/current

TARGETS := $(shell ls tests/ | grep -v current)
JOBS := $(addprefix job,${TARGETS})
.PHONY: all_results ${JOBS}

all_results: ${JOBS} ; echo "$@ successfully generated."
${JOBS}: job%: ; Rscript --vanilla priv/summary.r -i tests/$*
