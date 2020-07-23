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
function add_dv_UnservedLoad_constraints(m,p)
    # effective load balance (with slack in dvUnservedLoad)
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvUnservedLoad][s, tz, ts] >= p.elec_load.critical_loads_kw[tz+ts]
        - sum(  m[:dvMGRatedProduction][t, s, tz, ts] * p.production_factor[t, tz+ts] * p.levelization_factor[t]
            for t in p.techs
        )
        - m[:dvMGDischargeFromStorage][s, tz, ts]
    )
end


function add_outage_cost_constraints(m,p)
    # TODO: fixed cost, account for outage_is_major_event
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMaxOutageCost][s] >= p.pwf_e * sum(p.VoLL[tz+ts] * m[:dvUnservedLoad][s, tz, ts] for ts in 1:p.elecutil.outage_durations[s])
    )

    @expression(m, ExpectedOutageCost,
        sum(m[:dvMaxOutageCost][s] * p.elecutil.outage_probabilities[s] for s in p.elecutil.scenarios)
    )

    @constraint(m, [t in p.techs],
        m[:binMGTechUsed][t] => {m[:dvMGTechUpgradeCost][t] >= p.microgrid_premium_pct * p.two_party_factor *
		                         p.cap_cost_slope[t] * m[:dvSize][t]}
    )

    @constraint(m, [t in p.techs],
        m[:binMGTechUsed][t] => {m[:dvSize][t] >= 1.0}  # 1 kW min size to prevent binaryMGTechUsed = 1 with zero cost
    )

    @constraint(m,
        m[:binMGStorageUsed] => {m[:dvMGStorageUpgradeCost] >= p.microgrid_premium_pct * m[:TotalStorageCapCosts]}
    )

    @constraint(m, [b in p.storage.types],
        m[:binMGStorageUsed] => {m[:dvStoragePower][b] >= 1.0} # 1 kW min size to prevent binaryMGStorageUsed = 1 with zero cost
    )
    
    @expression(m, mgTotalTechUpgradeCost,
        sum( m[:dvMGTechUpgradeCost][t] for t in p.techs )
    )
end


function add_MG_production_constraints(m,p)

	# Electrical production sent to storage or export must be less than technology's rated production
	@constraint(m, [t in p.techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
		m[:dvMGProductionToStorage][t, s, tz, ts] + m[:dvMGCurtail][t, s, tz, ts] <=
		p.production_factor[t, tz+ts] * p.levelization_factor[t] * m[:dvMGRatedProduction][t, s, tz, ts]
    )

    if !isempty(p.gentechs)
        @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps], 
            m[:dvMGRatedProduction][t, s, tz, ts] in MOI.Semicontinuous(p.generator.min_turn_down_pct, p.max_sizes[t])
        )
        other_techs = setdiff(p.techs, p.gentechs)
        @constraint(m, [t in other_techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps], 
            m[:dvMGRatedProduction][t, s, tz, ts] >= 0
        )
    else
        @constraint(m, [t in p.techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps], 
            m[:dvMGRatedProduction][t, s, tz, ts] >= 0
        )
    end
    
    @constraint(m, [t in p.techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvMGRatedProduction][t, s, tz, ts] <= m[:dvSize][t]
    )
end


function add_MG_fuel_burn_constraints(m,p)
    # Define dvMGFuelUsed by summing over outage timesteps.
    @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGFuelUsed][t, s, tz] == p.generator.fuel_slope_gal_per_kwh * p.hours_per_timestep * p.levelization_factor[t] *
        sum( p.production_factor[t, tz+ts] * m[:dvMGRatedProduction][t, s, tz, ts] for ts in 1:p.elecutil.outage_durations[s])
        + p.generator.fuel_intercept_gal_per_hr * p.hours_per_timestep * 
        sum( m[:binMGGenIsOnInTS][s, tz, ts] for ts in 1:p.elecutil.outage_durations[s])
    )

    # For each outage the fuel used is <= fuel_avail_gal
    @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGFuelUsed][t, s, tz] <= p.generator.fuel_avail_gal
    )
    
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGMaxFuelUsage][s] >= sum( m[:dvMGFuelUsed][t, s, tz] for t in p.gentechs )
    )
    
    @expression(m, ExpectedMGFuelUsed, 
        sum( m[:dvMGMaxFuelUsage][s] * p.elecutil.outage_probabilities[s] for s in p.elecutil.scenarios )
    )

    # fuel cost = gallons * $/gal for each tech, outage
    @expression(m, MGFuelCost[t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGFuelUsed][t, s, tz] * p.generator.fuel_cost_per_gallon
    )
    
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGMaxFuelCost][s] >= sum( MGFuelCost[t, s, tz] for t in p.gentechs )
    )
    
    @expression(m, ExpectedMGFuelCost,
        sum( m[:dvMGMaxFuelCost][s] * p.elecutil.outage_probabilities[s] for s in p.elecutil.scenarios )
    )
end


function add_binMGGenIsOnInTS_constraints(m,p)
    # The following 2 constraints define binMGGenIsOnInTS to be the binary corollary to dvMGRatedProd for generator,
    # i.e. binMGGenIsOnInTS = 1 for dvMGRatedProd > min_turn_down_pct * dvSize, and binMGGenIsOnInTS = 0 for dvMGRatedProd = 0
    @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        !m[:binMGGenIsOnInTS][s, tz, ts] => { m[:dvMGRatedProduction][t, s, tz, ts] <= 0 }
    )
    @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:binMGGenIsOnInTS][s, tz, ts] => { 
            m[:dvMGRatedProduction][t, s, tz, ts] >= p.generator.min_turn_down_pct * m[:dvSize][t]
        }
    )
    @constraint(m, [t in p.gentechs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:binMGTechUsed][t] >= m[:binMGGenIsOnInTS][s, tz, ts]
    )
    # TODO? make binMGGenIsOnInTS indexed on p.gentechs
end


function add_MG_storage_dispatch_constraints(m,p)
    # initial SOC at start of each outage equals the grid-optimal SOC
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps],
        m[:dvMGStoredEnergy][s, tz, 0] <= m[:dvStoredEnergy][:elec, tz]
    )
    
    # state of charge
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvMGStoredEnergy][s, tz, ts] == m[:dvMGStoredEnergy][s, tz, ts-1] + p.hours_per_timestep * (
            p.storage.charge_efficiency[:elec] * sum(m[:dvMGProductionToStorage][t, s, tz, ts] for t in p.techs)
            - m[:dvMGDischargeFromStorage][s, tz, ts] / p.storage.discharge_efficiency[:elec]
        )
    )

    # Minimum state of charge
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvMGStoredEnergy][s, tz, ts] >=  p.storage.soc_min_pct[:elec] * m[:dvStorageEnergy][:elec]
    )
    
    # Dispatch to MG electrical storage is no greater than inverter capacity
    # and can't charge the battery unless binMGStorageUsed = 1
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvStoragePower][:elec] >= sum(m[:dvMGProductionToStorage][t, s, tz, ts] for t in p.techs)
    )
    
    # Dispatch from MG storage is no greater than inverter capacity
    # and can't discharge from storage unless binMGStorageUsed = 1
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvStoragePower][:elec] >= m[:dvMGDischargeFromStorage][s, tz, ts]
    )
    
    # Dispatch to and from electrical storage is no greater than power capacity
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvStoragePower][:elec] >= m[:dvMGDischargeFromStorage][s, tz, ts]
            + sum(m[:dvMGProductionToStorage][t, s, tz, ts] for t in p.techs)
    )
    
    # State of charge upper bound is storage system size
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        m[:dvStorageEnergy][:elec] >= m[:dvMGStoredEnergy][s, tz, ts]
    )
    
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        !m[:binMGStorageUsed] => { sum(m[:dvMGProductionToStorage][t, s, tz, ts] for t in p.techs) <= 0 }
    )
    
    @constraint(m, [s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
        !m[:binMGStorageUsed] => { m[:dvMGDischargeFromStorage][s, tz, ts] <= 0 }
    )
end


function add_cannot_have_MG_with_only_PVwind_constraints(m, p)
    renewable_techs = setdiff(p.techs, p.gentechs)
    # can't "turn down" renewable_techs
    if !isempty(renewable_techs)
        @constraint(m, [t in renewable_techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
            m[:binMGTechUsed][t] => { m[:dvMGRatedProduction][t, s, tz, ts] >= m[:dvSize][t] }
        )
        @constraint(m, [t in renewable_techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
            !m[:binMGTechUsed][t] => { m[:dvMGRatedProduction][t, s, tz, ts] <= 0 }
        )
        if !isempty(p.gentechs) # PV or Wind alone cannot be used for a MG
            @constraint(m, [t in renewable_techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
                m[:binMGTechUsed][t] => { sum(m[:binMGTechUsed][tek] for tek in p.gentechs) + m[:binMGStorageUsed] >= 1 }
            )
        else
            @constraint(m, [t in renewable_techs, s in p.elecutil.scenarios, tz in p.elecutil.outage_start_timesteps, ts in p.elecutil.outage_timesteps],
                m[:binMGTechUsed][t] => { m[:binMGStorageUsed] >= 1 }
            )
        end
    end
end