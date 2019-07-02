#NOTE see README for explanations

mkpath("output/")
outdir="output"

using Bridge, StaticArrays, Distributions
using Test, Statistics, Random, LinearAlgebra
using DataFrames
using CSV
using ForwardDiff: value
const ℝ = SVector{N,T} where {N,T}
# specify observation scheme
L = @SMatrix [1. 0.]
Σdiagel = 10^(-5)
Σ = @SMatrix [Σdiagel]

# choose parametrisation of the FitzHugh-Nagumo
POSSIBLE_PARAMS = [:regular, :simpleAlter, :complexAlter, :simpleConjug,
                   :complexConjug]
parametrisation = POSSIBLE_PARAMS[3]
include("src/fitzHughNagumo.jl")
include("src/fitzHughNagumo_conjugateUpdt.jl")

#NOTE important! MCMCBridge must be imported after FHN is loaded
#include("src/MCMCBridge.jl")
#using Main.MCMCBridge
include("src/types.jl")
include("src/ralston3.jl")
include("src/rk4.jl")
include("src/tsit5.jl")
include("src/vern7.jl")

include("src/priors.jl")

include("src/guid_prop_bridge.jl")
include("src/random_walk.jl")
include("src/mcmc.jl")

include("src/save_to_files.jl")


# Functions fetching the data. Data can be generated by functions in file 'simulate_data.jl'
function readData(::Val{true}, filename)
    df = CSV.read(filename)
    x0 = ℝ{2}(df.upCross[1], df.x2[1])
    obs = ℝ{1}.(df.upCross)
    obsTime = Float64.(df.time)
    fpt = [FPTInfo((1,), (true,), (resetLvl,), (i==1,)) for
            (i, resetLvl) in enumerate(df.downCross[2:end])]
    fptOrPartObs = FPT()
    df, x0, obs, obsTime, fpt, fptOrPartObs
end

function readData(::Val{false}, filename)
    df = CSV.read(filename)
    obs = ℝ{1}.(df.x1)
    obsTime = Float64.(df.time)
    x0 = ℝ{2}(df.x1[1], df.x2[1])
    fpt = [NaN for _ in obsTime[2:end]]
    fptOrPartObs = PartObs()
    df, x0, obs, obsTime, fpt, fptOrPartObs
end

# decide if first passage time observations or partially observed diffusion
fptObsFlag = true
if fptObsFlag
    filename = "up_crossing_times_short_regular.csv"
else
    filename = "path_part_obs_conj.csv"
end
(df, x0, obs, obsTime, fpt,
    fptOrPartObs) = readData(Val(fptObsFlag),
                             joinpath(outdir, filename))
#x0 = regularToConjug(x0, 10.0, 0)
x0 = regularToAlter(x0, 0.1, 0.0)
fpt
# Initial parameter guess.
#θ₀ = [0.2, 0.0, 1.5, 0.8, 0.3]
#θ₀ = [10.0, 0.0, 10.0, 18.0, 3.0]
θ₀ = [0.1, 0.0, 1.5, 1.6, 0.3]
#θ₀ = [0.4, 0.05, 1.2, 0.3, 0.2]
#θ₀ = [0.4, 0.05, 1.8, 0.6, 0.2]
# Target law
P˟ = FitzhughDiffusion(θ₀...)
# Auxiliary law
P̃ = [FitzhughDiffusionAux(θ₀..., t₀, u[1], T, v[1]) for (t₀,T,u,v)
     in zip(obsTime[1:end-1], obsTime[2:end], obs[1:end-1], obs[2:end])]
Ls = [L for _ in P̃]
Σs = [Σ for _ in P̃]
τ(t₀,T) = (x) ->  t₀ + (x-t₀) * (2-(x-t₀)/(T-t₀))
numSteps=2*10^4
tKernel = RandomWalk([0.015, 5.0, 0.05, 0.05, 0.5],
                     [false, false, false, false, true])
#tKernel=RandomWalk([0.005, 0.1, 0.1, 0.01, 0.1],
#                   [false, false, false, false, true])
#priors = Priors((MvNormal([0.0,0.0,0.0], diagm(0=>[1000.0, 1000.0, 1000.0])),
#                 ImproperPrior(),))
priors = Priors((ImproperPrior(),
                 #ImproperPrior()
                 )
                #(ImproperPrior(),)
                )

Random.seed!(5)
(chain, accRateImp, accRateUpdt,
    paths, time_) = mcmc(eltype(x0), fptOrPartObs, obs, obsTime, x0, 0.0, P˟, P̃, Ls, Σs,
                         numSteps, tKernel, priors, τ;
                         fpt=fpt,
                         ρ=0.996,
                         dt=1/1000,
                         saveIter=1*10^0,
                         verbIter=10^2,
                         updtCoord=(Val((false, false, false, true, false)),
                                    #Val((true, false, false, false, false)),
                                    #Val((false, true, false, false, false)),
                                    #Val((false, false, true, false, false)),
                                    #Val((true, false, false, false, false)),
                                    ),
                         paramUpdt=true,
                         updtType=(#ConjugateUpdt(),
                                   #MetropolisHastingsUpdt(),
                                   #MetropolisHastingsUpdt(),
                                   MetropolisHastingsUpdt(),
                                   #MetropolisHastingsUpdt(),
                                   ),
                         skipForSave=10^1,
                         solver=Vern7())

print("imputation acceptance rate: ", accRateImp,
      ", parameter update acceptance rate: ", accRateUpdt)

# save the results
if parametrisation in (:simpleAlter, :complexAlter)
    pathsToSave = [[alterToRegular(e, θ[1], θ[2]) for e in path] for (path,θ)
                                      in zip(paths, chain[1:length(priors)*1*10^0:end][2:end])]
    # only one out of many starting points will be plotted
    x0 = alterToRegular(x0, chain[1][1], chain[1][2])
elseif parametrisation in (:simpleConjug, :complexConjug)
    pathsToSave = [[conjugToRegular(e, θ[1], 0) for e in path] for (path,θ)
                                      in zip(paths, chain[1:length(priors)*3*10^3:end][2:end])]
    x0 = conjugToRegular(x0, chain[1][1], 0)
else
    pathsToSave = paths
end

#df2 = savePathsToFile(pathsToSave, time_, joinpath(outdir, "sampled_paths.csv"))
#df3 = saveChainToFile(chain, joinpath(outdir, "chain.csv"))

df2 = savePathsToFile(pathsToSave, time_, joinpath(outdir, "sampled_paths_fpt_short_bridges.csv"))
df3 = saveChainToFile(chain, joinpath(outdir, "chain_fpt_short_bridges.csv"))

include("src/plots.jl")
# make some plots
set_default_plot_size(30cm, 20cm)
#if fptObsFlag
#    plotPaths(df2, obs=[Float64.(df.upCross), [x0[2]]],
#              obsTime=[Float64.(df.time), [0.0]], obsCoords=[1,2])
#else
#    plotPaths(df2, obs=[Float64.(df.x1), [x0[2]]],
#              obsTime=[Float64.(df.time), [0.0]], obsCoords=[1,2])
#end
plotChain(df3, coords=[1])
#plotChain(df3, coords=[2])
plotChain(df3, coords=[3])
plotChain(df3, coords=[4])
#plotChain(df3, coords=[5])
