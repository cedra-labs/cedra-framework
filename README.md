# The Cedra Framework Repo

This repository serves as a mirror for the Cedra Framework packages, including the Move standard library. The contents are synced from [cedra-network](https://github.com/cedra-labs/cedra-network) on an hourly basis.

By pulling dependencies from this mirror repository, developers can avoid downloading unnecessary data, reducing build time significantly.

## Usage
To use the packages in this repository as dependencies in your Move project, you can include them in your move.toml file by adding them as Git dependencies.

To add a dependency from this repository, include the following in your `move.toml` file:
```
[dependencies]
<package_name> = { git = "https://github.com/cedra-labs/cedra-framework.git", subdir = "<path_to_directory_containing_Move.toml>", rev = "<commit_hash_or_branch_name>" }
```
For example, to add `CedraFramework` from the `mainnet` branch, you would use:
```
CedraFramework = { git = "https://github.com/cedra-labs/cedra-framework.git", subdir = "cedra-framework", rev = "mainnet" }
```
Make sure to replace `subdir` with the appropriate path if you are referencing a different package within the framework.

## Contributing
If you want to contribute to the development of the framework, please submit issues and pull requests to the [cedra-network](https://github.com/cedra-labs/cedra-network) repository, where active development happens.

Bugs, feature requests, or discussions of enhancements will be tracked in the issue section there as well. This repository is a mirror, and issues will not be tracked here.

## Compilation and Generation

The documents above were created by the Move documentation generator for Cedra. It is available as part of the Cedra CLI. To see its options, run:
```shell
cedra move document --help
```

The documentation process is also integrated into the framework building process and will be automatically triggered like other derived artifacts, via `cached-packages` or explicit release building.

## Running Move tests

To test our Move code while developing the Cedra Framework, run `cargo test` inside this directory:

```
cargo test
```

(Alternatively, run `cargo test -p cedra-framework` from anywhere.)

To skip the Move prover tests, run:

```
cargo test -- --skip prover
```

To filter and run **all** the tests in specific packages (e.g., `cedra_stdlib`), run:

```
cargo test -- cedra_stdlib --skip prover
```

(See tests in `tests/move_unit_test.rs` to determine which filter to use; e.g., to run the tests in `cedra_framework` you must filter by `move_framework`.)

To **filter by test name or module name** in a specific package (e.g., run the `test_empty_range_proof` in `cedra_stdlib::ristretto255_bulletproofs`), run:

```
TEST_FILTER="test_range_proof" cargo test -- cedra_stdlib --skip prover
```

Or, e.g., run all the Bulletproof tests:
```
TEST_FILTER="bulletproofs" cargo test -- cedra_stdlib --skip prover
```

To show the amount of time and gas used in every test, set env var `REPORT_STATS=1`.
E.g.,
```
REPORT_STATS=1 TEST_FILTER="bulletproofs" cargo test -- cedra_stdlib --skip prover
```

Sometimes, Rust runs out of stack memory in dev build mode.  You can address this by either:
1. Adjusting the stack size

```
export RUST_MIN_STACK=4297152
```

2. Compiling in release mode

```
cargo test --release -- --skip prover
```

## Layout
The overall structure of the Cedra Framework is as follows:

```
├── cedra-framework                                 # Sources, testing and generated documentation for Cedra framework component
├── cedra-token                                 # Sources, testing and generated documentation for Cedra token component
├── cedra-stdlib                                 # Sources, testing and generated documentation for Cedra stdlib component
├── move-stdlib                                 # Sources, testing and generated documentation for Move stdlib component
├── cached-packages                                 # Tooling to generate SDK from move sources.
├── src                                     # Compilation and generation of information from Move source files in the Cedra Framework. Not designed to be used as a Rust library
├── releases                                    # Move release bundles
└── tests
```
