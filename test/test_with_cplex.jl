# *********************************************************************************
# REopt, Copyright (c) 2019-2020, Alliance for Sustainable Energy, LLC.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification,
# are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this list
# of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice, this
# list of conditions and the following disclaimer in the documentation and/or other
# materials provided with the distribution.
#
# Neither the name of the copyright holder nor the names of its contributors may be
# used to endorse or promote products derived from this software without specific
# prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
# OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
# OF THE POSSIBILITY OF SUCH DAMAGE.
# *********************************************************************************
using Test
using JuMP
using CPLEX
using JSON
using REoptLite


@testset "BAU Scenario" begin
    model = Model(optimizer_with_attributes(CPLEX.Optimizer, "CPX_PARAM_SCRIND" => 0))
    results = run_reopt(model, "./scenarios/no_techs.json")
    @test all(isapprox.(results["GridToLoad"], results["inputs"].elec_load, atol=0.001))
end


@testset "January Export Rates" begin
    model = Model(optimizer_with_attributes(CPLEX.Optimizer, "CPX_PARAM_SCRIND" => 0))
    data = JSON.parsefile("./scenarios/monthly_rate.json")

    # create wholesale_rate with compensation in January > retail rate
    jan_rate = data["ElectricTariff"]["monthly_energy_rates"][1]
    data["ElectricTariff"]["wholesale_rate"] = 
        append!(repeat([jan_rate + 0.1], 31 * 24), repeat([0.0], 8760 - 31*24))
    data["ElectricTariff"]["monthly_demand_rates"] = repeat([0], 12)

    s = Scenario(data)
    inputs = REoptInputs(s)
    results = run_reopt(model, inputs)

    @test results["PV_kw"] ≈ 70.3084 atol=0.01
    @test results["lcc"] ≈ 430747.0 rtol=1e-5 # with levelization_factor hack the LCC is with 5e-5 of REopt Lite API LCC
    @test all(x == 0.0 for x in results["PVtoLoad"][1:744])
end


@testset "Solar and Storage" begin
    model = Model(optimizer_with_attributes(CPLEX.Optimizer, "CPX_PARAM_SCRIND" => 0))
    results = run_reopt(model, "./scenarios/pv_storage.json")

    @test results["PV_kw"] ≈ 216.6667 atol=0.01
    @test results["lcc"] ≈ 1.23887e7 rtol=1e-5
    @test results["batt_kw"] ≈ 55.82 atol=0.01
    @test results["batt_kwh"] ≈ 78.6885 atol=0.01
end



## equivalent REopt Lite API Post for test 2:
#   NOTE have to hack in API levelization_factor to get LCC within 5e-5 (Mosel tol)
# {"Scenario": {
#     "Site": {
#         "longitude": -118.1164613,
#         "latitude": 34.5794343,
#         "roof_squarefeet": 5000.0,
#         "land_acres": 1.0,
#     "PV": {
#         "macrs_bonus_pct": 0.4,
#         "installed_cost_us_dollars_per_kw": 2000.0,
#         "tilt": 34.579,
#         "degradation_pct": 0.005,
#         "macrs_option_years": 5,
#         "federal_itc_pct": 0.3,
#         "module_type": 0,
#         "array_type": 1,
#         "om_cost_us_dollars_per_kw": 16.0,
#         "macrs_itc_reduction": 0.5,
#         "azimuth": 180.0,
#         "federal_rebate_us_dollars_per_kw": 350.0,
#         "dc_ac_ratio": 1.1
#     },
#     "LoadProfile": {
#         "doe_reference_name": "RetailStore",
#         "annual_kwh": 10000000.0,
#         "city": "LosAngeles"
#     },
#     "Storage": {
#         "total_rebate_us_dollars_per_kw": 100.0,
#         "macrs_option_years": 5,
#         "can_grid_charge": true,
#         "macrs_bonus_pct": 0.4,
#         "macrs_itc_reduction": 0.5,
#         "total_itc_pct": 0,
#         "installed_cost_us_dollars_per_kw": 1000.0,
#         "installed_cost_us_dollars_per_kwh": 500.0,
#         "replace_cost_us_dollars_per_kw": 460.0,
#         "replace_cost_us_dollars_per_kwh": 230.0
#     },
#     "ElectricTariff": {
#         "urdb_label": "5ed6c1a15457a3367add15ae"
#     },
#     "Financial": {
#         "escalation_pct": 0.026,
#         "offtaker_discount_pct": 0.081,
#         "owner_discount_pct": 0.081,
#         "analysis_years": 20,
#         "offtaker_tax_pct": 0.4,
#         "owner_tax_pct": 0.4,
#         "om_cost_escalation_pct": 0.025
#     }
# }}}