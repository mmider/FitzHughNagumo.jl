using Makie
using Bridge
using Bridge: increment
using StaticArrays
using Trajectories
using Colors
import Trajectories: Trajectory, @unroll1
Trajectory(X::SamplePath) = Trajectory(X.tt, X.yy)

const parametrisation = :regular
include("../src/fitzHughNagumo.jl")
P = FitzhughDiffusion(0.1, 0.0, 1.5, 0.8, 0.3)
#P = FitzhughDiffusion(10.0, -8.0, 15.0, 0.0, 3.0)
Wnr = Wiener()
x0 = ℝ{2}(-0.5, -0.6)
L = @SMatrix [1. 0.]

dt = 1e-3
T = 30.0
tt = 0.0:dt:T

function simulateSegment(::S, tt, x0, P, W) where S
    WW = Bridge.samplepath(tt, zero(S))
    sample!(WW, Wnr)
    X = Trajectory(solve(Euler(), x0, WW, P))
    X, X.x[end]
end

X, _ = simulateSegment(0.0, tt, x0, P, Wnr)

k = 50


xraw = [X.x[1:10:end] for i in 1:k]
x = [Node(xraw[i]) for i in 1:k]
col = [Node(RGBA{Float32}(0.0, 0.0, 0.0, 0.0)) for i in 1:k]
c = 1
ms = 0.01
i = 1;
p = Scene(resolution=(1000,1000))
for i in randperm(k)
    scatter!(p, x[i], color = col[i], markersize = ms)
end
display(p)

function update!(t, x, y, dt, P, W)
    for i in eachindex(x)
        y[i] = x[i] + b(t, x[i], P)*dt + σ(t, x[i], P)*rand(increment(dt, W))
    end
    y
end

update!(x, y, dt, P, W) = update!(NaN, x, y, dt, P, W)
sleep(1)
N = 3000
for i in 1:N
    global c
    cnew = mod1(c+1, k)
    update!(x[c][], x[cnew][], dt, P, Wnr)
    c = cnew
    x[c][] = x[cnew][]

    for i in 0:k-1
        f = (i + 5*(i!=0))/(k+5)
        col[mod1(c-i, k)][] = RGBA{Float32}(0.2, 0.3, 1.0, (1-f)/2)
    end
    sleep(1e-8)
end
#=
record(p, "output/fitzhugh.mp4", 1:N) do i
    global c
    cnew = mod1(c+1, k)
    update!(x[c][], x[cnew][], dt, P, Wnr)
    c = cnew
    x[c][] = x[cnew][]
    #f = mod1(i, 3k)/3k
    #col[mod1(c, k)][] = RGB{Float32}(f, f, 1-f)
    for i in 0:k-1
        f = (i + 5*(i!=0))/(k+5)
        col[mod1(c-i, k)][] = RGB{Float32}(f, f, 1.0)
    end
end
=#
