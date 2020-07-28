include("./src/REoptLite.jl")
using JuMP
using Xpress
using Main.REoptLite


function run()
    m = Model(optimizer_with_attributes(Xpress.Optimizer, "logfile" => "output.log"))
    results = run_reopt(m, "test/scenarios/sseb_2wk_outage_no_grid.json")
    # need to chop off end of outage start time steps according to outage_durations

    open("results.json","w") do f    #substitute FILE_NAME with applicable scenario json
        JSON.print(f, results)
        end 
    # TODO sweep VoLL
end