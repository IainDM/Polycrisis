# Earth4All persistent Julia worker process
# Keeps Earth4All.jl loaded in memory to avoid recompilation overhead.
# Communicates via line-delimited JSON on stdin/stdout.
#
# Protocol:
#   → Client sends one JSON object per line on stdin
#   ← Worker responds with one JSON object per line on stdout
#   → Client sends {"command": "exit"} to shut down
#
# Commands:
#   {"command": "ping"}
#     → {"status": "ok", "message": "pong"}
#
#   {"command": "run", "parameters": {...}, "initialisations": {...}, "variables": [...]}
#     → {"success": true, "dashboard": [...], "timeseries": {...}, ...}
#
#   {"command": "exit"}
#     → worker shuts down

using JSON

# Get Earth4All.jl source path
const E4A_SRC = if length(ARGS) >= 1
    ARGS[1]
elseif haskey(ENV, "EARTH4ALL_SRC")
    ENV["EARTH4ALL_SRC"]
else
    joinpath(@__DIR__, "..", "Earth4All.jl", "src")
end

# Signal that we're starting up
println(stderr, "earth4all-worker: loading Earth4All.jl from $E4A_SRC...")
flush(stderr)

try
    include(joinpath(E4A_SRC, "Earth4All.jl"))
    println(stderr, "earth4all-worker: Earth4All.jl loaded successfully")
    flush(stderr)
catch e
    println(stderr, "earth4all-worker: FATAL - failed to load Earth4All.jl: $(sprint(showerror, e))")
    flush(stderr)
    exit(1)
end

using ModelingToolkit

# Sector mapping (same as run_earth4all.jl)
const SECTOR_MAP = Dict(
    "climate" => (getparams=Earth4All.Climate.getparameters, getinits=Earth4All.Climate.getinitialisations, pars_kw=:cli_pars, inits_kw=:cli_inits),
    "demand" => (getparams=Earth4All.Demand.getparameters, getinits=Earth4All.Demand.getinitialisations, pars_kw=:dem_pars, inits_kw=:dem_inits),
    "energy" => (getparams=Earth4All.Energy.getparameters, getinits=Earth4All.Energy.getinitialisations, pars_kw=:ene_pars, inits_kw=:ene_inits),
    "finance" => (getparams=Earth4All.Finance.getparameters, getinits=Earth4All.Finance.getinitialisations, pars_kw=:fin_pars, inits_kw=:fin_inits),
    "foodland" => (getparams=Earth4All.FoodLand.getparameters, getinits=Earth4All.FoodLand.getinitialisations, pars_kw=:foo_pars, inits_kw=:foo_inits),
    "inventory" => (getparams=Earth4All.Inventory.getparameters, getinits=Earth4All.Inventory.getinitialisations, pars_kw=:inv_pars, inits_kw=:inv_inits),
    "labourmarket" => (getparams=Earth4All.LabourMarket.getparameters, getinits=Earth4All.LabourMarket.getinitialisations, pars_kw=:lab_pars, inits_kw=:lab_inits),
    "other" => (getparams=Earth4All.Other.getparameters, getinits=Earth4All.Other.getinitialisations, pars_kw=:oth_pars, inits_kw=:oth_inits),
    "output" => (getparams=Earth4All.Output.getparameters, getinits=Earth4All.Output.getinitialisations, pars_kw=:out_pars, inits_kw=:out_inits),
    "population" => (getparams=Earth4All.Population.getparameters, getinits=Earth4All.Population.getinitialisations, pars_kw=:pop_pars, inits_kw=:pop_inits),
    "public" => (getparams=Earth4All.Public.getparameters, getinits=Earth4All.Public.getinitialisations, pars_kw=:pub_pars, inits_kw=:pub_inits),
    "wellbeing" => (getparams=Earth4All.Wellbeing.getparameters, getinits=Earth4All.Wellbeing.getinitialisations, pars_kw=:wel_pars, inits_kw=:wel_inits),
)

function handle_run(input::Dict)
    warnings = String[]
    t_start = time()

    kwargs = Dict{Symbol, Any}()
    param_overrides = get(input, "parameters", Dict())
    init_overrides = get(input, "initialisations", Dict())

    for (sector_name, sector_info) in SECTOR_MAP
        pars = sector_info.getparams()
        if haskey(param_overrides, sector_name)
            for (k, v) in param_overrides[sector_name]
                sym = Symbol(k)
                if haskey(pars, sym)
                    pars[sym] = Float64(v)
                else
                    push!(warnings, "Unknown parameter $sector_name.$k — skipped")
                end
            end
        end
        kwargs[sector_info.pars_kw] = pars

        inits = sector_info.getinits()
        if haskey(init_overrides, sector_name)
            for (k, v) in init_overrides[sector_name]
                sym = Symbol(k)
                if haskey(inits, sym)
                    inits[sym] = Float64(v)
                else
                    push!(warnings, "Unknown initialisation $sector_name.$k — skipped")
                end
            end
        end
        kwargs[sector_info.inits_kw] = inits
    end

    sol = Earth4All.run_e4a_solution(; kwargs...)
    solve_time = time() - t_start

    @named pop = Earth4All.Population.population()
    @named cli = Earth4All.Climate.climate()
    @named dem = Earth4All.Demand.demand()
    @named wel = Earth4All.Wellbeing.wellbeing()

    milestone_years = [2025, 2050, 2075, 2100]
    dashboard = []

    for year in milestone_years
        idx = argmin(abs.(sol.t .- year))
        push!(dashboard, Dict(
            "year" => year,
            "population_mp" => sol[pop.POP][idx],
            "gdp_per_person_k" => sol[pop.GDPP][idx],
            "warming_degC" => sol[cli.OW][idx],
            "inequality" => sol[dem.INEQ][idx],
            "wellbeing_index" => sol[wel.AWBI][idx],
            "social_tension" => sol[wel.STE][idx],
        ))
    end

    timeseries = Dict()
    variable_map = Dict(
        "pop.POP" => pop.POP,
        "pop.GDPP" => pop.GDPP,
        "cli.OW" => cli.OW,
        "dem.INEQ" => dem.INEQ,
        "wel.AWBI" => wel.AWBI,
        "wel.STE" => wel.STE,
    )

    requested_vars = get(input, "variables", collect(keys(variable_map)))
    for var_name in requested_vars
        if haskey(variable_map, var_name)
            var_sym = variable_map[var_name]
            timeseries[var_name] = Dict(
                "times" => collect(sol.t),
                "values" => collect(sol[var_sym]),
            )
        end
    end

    return Dict(
        "success" => true,
        "message" => "Simulation completed successfully",
        "solve_time_seconds" => solve_time,
        "dashboard" => dashboard,
        "timeseries" => timeseries,
        "warnings" => warnings,
    )
end

function handle_command(input::Dict)
    command = get(input, "command", "run")

    if command == "ping"
        return Dict("status" => "ok", "message" => "pong")
    elseif command == "exit"
        return nothing  # signal to exit
    elseif command == "run"
        return handle_run(input)
    else
        return Dict("status" => "error", "message" => "Unknown command: $command")
    end
end

# Signal readiness
println(JSON.json(Dict("status" => "ready", "message" => "Earth4All worker ready")))
flush(stdout)

# Main loop
while !eof(stdin)
    line = readline(stdin)
    isempty(strip(line)) && continue

    try
        input = JSON.parse(line)
        result = handle_command(input)

        if result === nothing
            # Exit command
            break
        end

        println(JSON.json(result))
        flush(stdout)
    catch e
        error_result = Dict(
            "success" => false,
            "message" => "Error: $(sprint(showerror, e))",
            "solve_time_seconds" => 0,
            "dashboard" => [],
            "timeseries" => Dict(),
            "warnings" => [sprint(showerror, e, catch_backtrace())],
        )
        println(JSON.json(error_result))
        flush(stdout)
    end
end

println(stderr, "earth4all-worker: shutting down")
flush(stderr)
