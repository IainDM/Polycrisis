# Install Julia dependencies needed for Earth4All.jl
# Run: julia install_deps.jl

using Pkg

println("Installing Earth4All.jl dependencies...")

# Core dependencies
Pkg.add([
    "ModelingToolkit",
    "DifferentialEquations",
    "WorldDynamics",
    "JSON",
    "IfElse",
])

println("Dependencies installed successfully.")
println()
println("You also need Earth4All.jl source code:")
println("  git clone https://github.com/worlddynamics/Earth4All.jl")
println()
println("Set the EARTH4ALL_SRC environment variable to the src/ directory:")
println("  export EARTH4ALL_SRC=/path/to/Earth4All.jl/src")
