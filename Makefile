.PHONY: build run debug logs telemetry verify test clean

build:
	swift build

run:
	./script/build_and_run.sh

debug:
	./script/build_and_run.sh --debug

logs:
	./script/build_and_run.sh --logs

telemetry:
	./script/build_and_run.sh --telemetry

verify:
	./script/build_and_run.sh --verify

test:
	swift run VopauseCoreSmokeTests

clean:
	rm -rf .build dist
