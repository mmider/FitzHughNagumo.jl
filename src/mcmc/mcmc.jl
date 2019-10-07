import ForwardDiff: value # currently not needed, but will be
"""
    accept_sample(logThreshold, verbose=false)

Make a random MCMC decision for whether to accept a sample or reject it.
"""
function accept_sample(logThreshold, verbose=false)
    if rand(Exponential(1.0)) > -logThreshold # Reject if NaN
        verbose && print("\t ✓\n")
        return true
    else
        verbose && print("\t .\n")
        return false
    end
end


"""
    solve_back_rec!(P, solver::ST=Ralston3()) where ST

Solve backward recursion to find H, Hν, c and Q, which together define r̃(t,x)
and p̃(x, 𝓓) under the auxiliary law, when no blocking is done
"""
function solve_back_rec!(::NoBlocking, P, solver::ST=Ralston3()) where ST
    m = length(P)
    gpupdate!(P[m]; solver=ST())
    for i in (m-1):-1:1
        gpupdate!(P[i], P[i+1].H[1], P[i+1].Hν[1], P[i+1].c[1]; solver=ST())
    end
end


"""
    solve_back_rec!(P, solver::ST=Ralston3()) where ST

Solve backward recursion to find H, Hν, c and Q, which together define r̃(t,x)
and p̃(x, 𝓓) under the auxiliary law, when blocking is done
"""
function solve_back_rec!(ws::Workspace, P, solver::ST=Ralston3()) where ST
    𝔅 = ws.blocking
    for block in reverse(𝔅.blocks[ws.blidx])
        gpupdate!(P[block[end]]; solver=ST())
        for i in reverse(block[1:end-1])
            gpupdate!(P[i], P[i+1].H[1], P[i+1].Hν[1], P[i+1].c[1]; solver=ST())
        end
    end
end


choose_start_pt(::Val{1}, y, yᵒ) = copy(yᵒ)
choose_start_pt(::Any, y, yᵒ) = copy(y)


"""
    proposal_start_pt(::NoBlocking, ::Any, y₀, yPr, P, ρ)

Set a new starting point for the proposal path when no blocking is done
...
# Arguments
- `::NoBlocking`: indicator that no blocking is done
- `yPr`: prior over the starting point
- `P`: diffusion law
- `ρ`: memory parameter in the Crank-Nicolson scheme
...
"""
function proposal_start_pt(ws::Workspace, P)
    x0_prior, z = ws.x0_prior, ws.z.val
    zᵒ = rand(x0_prior, z, ws.ρ)
    yᵒ = start_pt(zᵒ, x0_prior, P)
    zᵒ, yᵒ
end

"""
    print_info(verbose::Bool, it::Integer, ll, llᵒ, msg="update")

Print information to the console about current likelihood values

...
# Arguments
- `verbose`: flag for whether to print anything at all
- `it`: iteration of the Markov chain
- `ll`: likelihood of the previous, accepted sample
- `llᵒ`: likelihood of the proposal sample
- `msg`: message to start with
...
"""
function print_info(verbose::Bool, it::Integer, ll, llᵒ, msg="update")
    verbose && print(msg, ": ", it, " ll ", round(ll, digits=3), " ",
                     round(llᵒ, digits=3), " diff_ll: ", round(llᵒ-ll,digits=3))
end


"""
    path_log_likhd(::ObsScheme, XX, P, iRange, fpt; skipFPT=false)

Compute likelihood for path `XX` to be observed under `P`. Only segments with
index numbers in `iRange` are considered. `fpt` contains relevant info about
checks regarding adherence to first passage time pattern. `skipFPT` if set to
`true` can skip the step of checking adherence to fpt pattern (used for
conjugate updates, or any updates that keep `XX` unchanged)
"""
function path_log_likhd(::ObsScheme, XX, P, iRange, fpt; skipFPT=false
                      ) where ObsScheme <: AbstractObsScheme
    ll = 0.0
    for i in iRange
        ll += llikelihood(LeftRule(), XX[i], P[i])
    end
    !skipFPT && (ll = checkFullPathFpt(ObsScheme(), XX, iRange, fpt) ? ll : -Inf)
    !skipFPT && (ll += checkDomainAdherence(P, XX, iRange) ? 0.0 : -Inf)
    ll
end

"""
    swap!(A, Aᵒ, iRange)

Swap contents between containers A & Aᵒ in the index range iRange
"""
function swap!(A, Aᵒ, iRange)
    for i in iRange
        A[i], Aᵒ[i] = Aᵒ[i], A[i]
    end
end

"""
    swap!(A, Aᵒ, B, Bᵒ, iRange)

Swap contents between containers A & Aᵒ in the index range iRange, do the same
for containers B & Bᵒ
"""
function swap!(A, Aᵒ, B, Bᵒ, iRange)
    swap!(A, Aᵒ, iRange)
    swap!(B, Bᵒ, iRange)
end

"""
    crank_nicolson!(yᵒ, y, ρ)

Preconditioned Crank-Nicolson update with memory parameter `ρ`, previous vector
`y` and new vector `yᵒ`
"""
crank_nicolson!(yᵒ, y, ρ) = (yᵒ .= √(1-ρ)*yᵒ + √(ρ)*y)


"""
    sample_segment!(i, ws, y)

Sample `i`th path segment using preconditioned Crank-Nicolson scheme
...
# Arguments
- `i`: index of the segment to be sampled
- `Wnr`: type of the Wiener process
- `WW`: containers with old Wiener paths
- `WWᵒ`: containers where proposal Wiener paths will be stored
- `P`: laws of the diffusion to be sampled
- `y`: starting point of the segment
- `XX`: containers for proposal diffusion path
- `ρ`: memory parameter for the Crank-Nicolson scheme
...
"""
function sample_segment!(i, ws, y)
    sample!(ws.WWᵒ[i], ws.Wnr)
    crank_nicolson!(ws.WWᵒ[i].yy, ws.WW[i].yy, ws.ρ)
    solve!(Euler(), ws.XXᵒ[i], y, ws.WWᵒ[i], ws.P[i])
    ws.XXᵒ[i].yy[end]
end

"""
    sample_segments!(iRange, Wnr, WW, WWᵒ, P, y, XX, ρ)

Sample paths segments in index range `iRange` using preconditioned
Crank-Nicolson scheme
...
# Arguments
- `iRange`: range of indices of the segments that need to be sampled
- `Wnr`: type of the Wiener process
- `WW`: containers with old Wiener paths
- `WWᵒ`: containers where proposal Wiener paths will be stored
- `P`: laws of the diffusion to be sampled
- `y`: starting point of the segment
- `XX`: containers for proposal diffusion path
- `ρ`: memory parameter for the Crank-Nicolson scheme
...
"""
function sample_segments!(iRange, ws, y)
    for i in iRange
        y = sample_segment!(i, ws, y)
    end
end

"""
    impute!(::ObsScheme, 𝔅::NoBlocking, Wnr, yPr, WWᵒ, WW, XXᵒ, XX, P, ll, fpt;
            ρ=0.0, verbose=false, it=NaN, headstart=false) where
            ObsScheme <: AbstractObsScheme -> acceptedLogLikhd, acceptDecision

Imputation step of the MCMC scheme (without blocking).
...
# Arguments
- `::ObsScheme`: observation scheme---first-passage time or partial observations
- `Wnr`: type of the Wiener process
- `yPr`: prior over the starting point of the diffusion path
- `WWᵒ`: containers for proposal Wiener paths
- `WW`: containers with old Wiener paths
- `XXᵒ`: containers for proposal diffusion paths
- `XX`: containers with old diffusion paths
- `P`: laws of the diffusion path (proposal and target)
- `11`: log-likelihood of the old (previously accepted) diffusion path
- `fpt`: info about first-passage time conditioning
- `ρ`: memory parameter for the Crank-Nicolson scheme
- `verbose`: whether to print updates info while sampling
- `it`: iteration index of the MCMC algorithm
- `headstart`: flag for whether to 'ease into' fpt conditions
...
"""
function impute!(ws::Workspace{ObsScheme,NoBlocking,ST}, ll, verbose=false,
                 it=NaN, headstart=false
                 ) where {ObsScheme <: AbstractObsScheme, ST}
    WWᵒ, WW, Pᵒ, P, XXᵒ, XX, fpt, ρ = ws.WWᵒ, ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX, ws.fpt, ws.ρ
    # sample proposal starting point
    zᵒ, yᵒ = proposal_start_pt(ws, P[1])

    # sample proposal path
    m = length(WWᵒ)
    y_temp = copy(yᵒ)
    for i in 1:m
        sample_segment!(i, ws, y_temp)
        if headstart
            while !checkFpt(ObsScheme(), XXᵒ[i], fpt[i])
                sample_segment!(i, ws, y_temp)
            end
        end
        y_temp = XXᵒ[i].yy[end]
    end

    llᵒ = logpdf(ws.x0_prior, yᵒ)
    llᵒ += path_log_likhd(ObsScheme(), XXᵒ, P, 1:m, fpt)
    llᵒ += lobslikelihood(P[1], yᵒ)

    print_info(verbose, it, value(ll), value(llᵒ), "impute")

    if accept_sample(llᵒ-ll, verbose)
        swap!(XX, XXᵒ, WW, WWᵒ, 1:m)
        set!(ws.z, zᵒ)
        return llᵒ, true
    else
        return ll, false
    end
end


"""
    noise_from_path!(𝔅::BlockingSchedule, XX, WW, P)

Compute driving Wiener noise `WW` from path `XX` drawn under law `P`
"""
function noise_from_path!(ws::Workspace, XX, WW, P)
    𝔅 = ws.blocking
    for block in 𝔅.blocks[ws.blidx]
        for i in block
            inv_solve!(Euler(), XX[i], WW[i], P[i])
        end
    end
end


"""
    start_pt_log_pdf(::Val{1}, yPr::StartingPtPrior, y)

Compute the log-likelihood contribution of the starting point for a given prior
under a blocking scheme (intended to be used with a first block only)
"""
start_pt_log_pdf(::Val{1}, x0_prior::StartingPtPrior, y) = logpdf(x0_prior, y)

"""
    start_pt_log_pdf(::Any, yPr::StartingPtPrior, y)

Default contribution to log-likelihood from the startin point under blocking
"""
start_pt_log_pdf(::Any, x0_prior::StartingPtPrior, y) = 0.0


"""
    impute!(::ObsScheme, 𝔅::ChequeredBlocking, Wnr, y, WWᵒ, WW, XXᵒ, XX, P, ll,
            fpt; ρ=0.0, verbose=false, it=NaN, headstart=false) where
            ObsScheme <: AbstractObsScheme -> acceptedLogLikhd, acceptDecision

Imputation step of the MCMC scheme (without blocking).
...
# Arguments
- `::ObsScheme`: observation scheme---first-passage time or partial observations
- `𝔅`: object with relevant information about blocking
- `Wnr`: type of the Wiener process
- `yPr`: prior over the starting point of the diffusion path
- `WWᵒ`: containers for proposal Wiener paths
- `WW`: containers with old Wiener paths
- `XXᵒ`: containers for proposal diffusion paths
- `XX`: containers with old diffusion paths
- `P`: laws of the diffusion path (proposal and target)
- `11`: log-likelihood of the old (previously accepted) diffusion path
- `fpt`: info about first-passage time conditioning
- `ρ`: memory parameter for the Crank-Nicolson scheme
- `verbose`: whether to print updates info while sampling
- `it`: iteration index of the MCMC algorithm
- `headstart`: flag for whether to 'ease into' fpt conditions
...
"""
function impute!(ws::Workspace{ObsScheme,ChequeredBlocking,ST}, ll,
                 verbose=false, it=NaN, headstart=false
                 ) where {ObsScheme <: AbstractObsScheme, ST}
    WWᵒ, WW, Pᵒ, P, XXᵒ, XX = ws.WWᵒ, ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX
    x0_prior = ws.x0_prior
    𝔅 = ws.blocking
    solve_back_rec!(ws, P, ST())         # compute (H, Hν, c) for given blocks
    noise_from_path!(ws, XX, WW, P) # find noise WW that generates XX under 𝔅.P

    # compute white noise generating starting point under 𝔅
    z = inv_start_pt(XX[1].yy[1], x0_prior, P[1])
    set!(ws.z, z)
    # proposal starting point:
    z_prop, y_prop = proposal_start_pt(ws, P)

    ll_total = 0.0
    for (block_idx, block) in enumerate(𝔅.blocks[ws.blidx])
        block_flag = Val{block[1]}()
        # previously accepted startin point
        y = XX[block[1]].yy[1]
        # proposal starting point for the block (can be non-y only for the first block)
        yᵒ = choose_start_pt(block_flag, y, y_prop)

        # sample path in block
        sample_segments!(block, ws, yᵒ)
        set_end_pt_manually!(block_idx, block, ws)

        # starting point, path and observations contribution
        llᵒ = start_pt_log_pdf(block_flag, x0_prior, yᵒ)
        llᵒ += path_log_likhd(ObsScheme(), XXᵒ, P, block, ws.fpt)
        llᵒ += lobslikelihood(P[block[1]], yᵒ)

        llPrev = start_pt_log_pdf(block_flag, x0_prior, y)
        llPrev += path_log_likhd(ObsScheme(), XX, P, block, ws.fpt; skipFPT=true)
        llPrev += lobslikelihood(P[block[1]], y)

        print_info(verbose, it, value(llPrev), value(llᵒ), "impute")
        if accept_sample(llᵒ-llPrev, verbose)
            swap!(XX, XXᵒ, block)
            register_accpt!(ws, block_idx, true)
            set_z!(block_flag, ws, z_prop)
            ll_total += llᵒ
        else
            register_accpt!(ws, block_idx, false)
            ll_total += llPrev
        end
    end
    # acceptance indicator does not matter for sampling with blocking
    return ll_total, true
end

set_z!(::Val{1}, ws::Workspace, zᵒ) = set!(ws.z, zᵒ)

set_z!(::Any, ::Workspace, ::Any) = nothing

"""
    update_laws!(Ps, θᵒ)

Set new parameter `θᵒ` for the laws in vector `Ps`
"""
function update_laws!(Ps, θᵒ)
    m = length(Ps)
    for i in 1:m
        Ps[i] = GuidPropBridge(Ps[i], θᵒ)
    end
end

function update_laws!(Ps, θᵒ, ws)
    𝔅 = ws.blocking
    for block in 𝔅.blocks[ws.blidx]
        for i in block
            Ps[i] = GuidPropBridge(Ps[i], θᵒ)
        end
    end
end



"""
    find_path_from_wiener!(XX, y, WW, P, iRange)

Find path `XX` (that starts from `y`) that is generated under law `P` from the
Wiener process `WW`. Only segments with indices in range `iRange` are considered
"""
function find_path_from_wiener!(XX, y, WW, P, iRange)
    for i in iRange
        solve!(Euler(), XX[i], y, WW[i], P[i])
        y = XX[i].yy[end]
    end
end


"""
    prior_kernel_contrib(tKern, priors, θ, θᵒ)

Contribution to the log-likelihood ratio from transition kernel `tKernel` and
`priors`.
"""
function prior_kernel_contrib(tKern, priors, θ, θᵒ)
    llr = logpdf(tKern, θᵒ, θ) - logpdf(tKern, θ, θᵒ)
    for prior in priors
        llr += logpdf(prior, θᵒ) - logpdf(prior, θ)
    end
    llr
end


"""
    set_end_pt_manually!(𝔅::BlockingSchedule, block_idx, block)

Manually set the end-point of the proposal path under blocking so that it agrees
with the end-point of the previously accepted path. If it is the last block,
then do nothing
"""
function set_end_pt_manually!(block_idx, block, ws::Workspace)
    𝔅 = ws.blocking
    if block_idx < length(𝔅.blocks[ws.blidx])
        ws.XXᵒ[block[end]].yy[end] = ws.XX[block[end]].yy[end]
    end
end


"""
    update_param!(::ObsScheme, ::MetropolisHastingsUpdt, tKern, θ, ::UpdtIdx,
                 yPr, WW, Pᵒ, P, XXᵒ, XX, ll, prior, fpt, recomputeODEs;
                 solver::ST=Ralston3(), verbose=false,
                 it=NaN) where {ObsScheme <: AbstractObsScheme, ST, UpdtIdx}
                 -> acceptedLogLikhd, acceptDecision
Update parameters
...
# Arguments
- `::ObsScheme`: observation scheme---first-passage time or partial observations
- `::MetropolisHastingsUpdt()`: type of the parameter update
- `tKern`: transition kernel
- `θ`: current value of the parameter
- `updtIdx`: object declaring indices of the updated parameter
- `yPr`: prior over the starting point of the diffusion path
- `WW`: containers with Wiener paths
- `Pᵒ`: container for the laws of the diffusion path with new parametrisation
- `P`: laws of the diffusion path with old parametrisation
- `XXᵒ`: containers for proposal diffusion paths
- `XX`: containers with old diffusion paths
- `11`: likelihood of the old (previously accepted) parametrisation
- `priors`: list of priors
- `fpt`: info about first-passage time conditioning
- `recomputeODEs`: whether auxiliary law depends on the updated params
- `verbose`: whether to print updates info while sampling
- `it`: iteration index of the MCMC algorithm
...
"""
function update_param!(pu::ParamUpdtDefn{MetropolisHastingsUpdt,UpdtIdx,ST},
                       θ, ws::Workspace{ObsScheme,NoBlocking}, ll,
                       verbose=false, it=NaN, uidx=NaN
                       ) where {ObsScheme <: AbstractObsScheme,UpdtIdx,ST}
    WW, Pᵒ, P, XXᵒ, XX, fpt = ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX, ws.fpt
    x0_prior = ws.x0_prior
    m = length(WW)
    θᵒ = rand(pu.t_kernel, θ, UpdtIdx())               # sample new parameter
    update_laws!(Pᵒ, θᵒ)
    pu.recompute_ODEs && solve_back_rec!(NoBlocking(), Pᵒ, ST()) # compute (H, Hν, c)

    # find white noise which for a given θᵒ gives a correct starting point
    y = XX[1].yy[1]
    zᵒ = inv_start_pt(y, x0_prior, Pᵒ[1])

    find_path_from_wiener!(XXᵒ, y, WW, Pᵒ, 1:m)

    llᵒ = logpdf(x0_prior, y)
    llᵒ += path_log_likhd(ObsScheme(), XXᵒ, Pᵒ, 1:m, fpt)
    llᵒ += lobslikelihood(Pᵒ[1], y)

    print_info(verbose, it, ll, llᵒ)

    llr = ( llᵒ - ll + prior_kernel_contrib(pu.t_kernel, pu.priors, θ, θᵒ))

    # Accept / reject
    if accept_sample(llr, verbose)
        swap!(XX, XXᵒ, P, Pᵒ, 1:m)
        set!(ws.z, zᵒ)
        return llᵒ, true, θᵒ
    else
        return ll, false, θ
    end
end



"""
    update_param!(::ObsScheme, ::MetropolisHastingsUpdt, tKern, θ, ::UpdtIdx,
                 yPr, WW, Pᵒ, P, XXᵒ, XX, ll, prior, fpt, recomputeODEs;
                 solver::ST=Ralston3(), verbose=false,
                 it=NaN) where {ObsScheme <: AbstractObsScheme, ST, UpdtIdx}
                 -> acceptedLogLikhd, acceptDecision
Update parameters
...
# Arguments
- `::ObsScheme`: observation scheme---first-passage time or partial observations
- `::MetropolisHastingsUpdt()`: type of the parameter update
- `tKern`: transition kernel
- `θ`: current value of the parameter
- `updtIdx`: object declaring indices of the updated parameter
- `yPr`: prior over the starting point of the diffusion path
- `WW`: containers with Wiener paths
- `Pᵒ`: container for the laws of the diffusion path with new parametrisation
- `P`: laws of the diffusion path with old parametrisation
- `XXᵒ`: containers for proposal diffusion paths
- `XX`: containers with old diffusion paths
- `11`: likelihood of the old (previously accepted) parametrisation
- `priors`: list of priors
- `fpt`: info about first-passage time conditioning
- `recomputeODEs`: whether auxiliary law depends on the updated params
- `verbose`: whether to print updates info while sampling
- `it`: iteration index of the MCMC algorithm
...
"""
function update_param!(pu::ParamUpdtDefn{MetropolisHastingsUpdt,UpdtIdx,ST},
                       θ, ws::Workspace{ObsScheme}, ll, verbose=false, it=NaN,
                       uidx=NaN) where {ObsScheme <: AbstractObsScheme,UpdtIdx,ST}
    WW, Pᵒ, P, XXᵒ, XX, fpt = ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX, ws.fpt
    x0_prior = ws.x0_prior
    𝔅 = ws.blocking
    m = length(P)
    θᵒ = rand(pu.t_kernel, θ, UpdtIdx())               # sample new parameter
    update_laws!(Pᵒ, θᵒ, ws)                   # update law `Pᵒ` accordingly
    solve_back_rec!(ws, Pᵒ, ST())                 # compute (H, Hν, c)

    y = XX[1].yy[1]
    zᵒ = inv_start_pt(y, x0_prior, Pᵒ[1])
    llᵒ = logpdf(x0_prior, y)
    for (block_idx, block) in enumerate(𝔅.blocks[ws.blidx])
        y = XX[block[1]].yy[1]
        find_path_from_wiener!(XXᵒ, y, WW, Pᵒ, block)
        set_end_pt_manually!(block_idx, block, ws)

        # Compute log-likelihood ratio
        llᵒ += path_log_likhd(ObsScheme(), XXᵒ, Pᵒ, block, ws.fpt)
        llᵒ += lobslikelihood(Pᵒ[block[1]], y)
    end
    print_info(verbose, it, ll, llᵒ)

    llr = ( llᵒ - ll + prior_kernel_contrib(pu.t_kernel, pu.priors, θ, θᵒ))

    # Accept / reject
    if accept_sample(llr, verbose)
        swap!(XX, XXᵒ, P, Pᵒ, 1:m)
        set!(ws.z, zᵒ)
        return llᵒ, true, θᵒ
    else
        return ll, false, θ
    end
end



"""
    update_param!(::PartObs, ::ConjugateUpdt, tKern, θ, ::UpdtIdx, yPr, WW, Pᵒ,
                 P, XXᵒ, XX, ll, priors, fpt, recomputeODEs;
                 solver::ST=Ralston3(), verbose=false, it=NaN
                 ) -> acceptedLogLikhd, acceptDecision
Update parameters
see the definition of  update_param!(…, ::MetropolisHastingsUpdt, …) for the
explanation of the arguments.
"""
function update_param!(pu::ParamUpdtDefn{ConjugateUpdt,UpdtIdx,ST},
                       θ, ws::Workspace{ObsScheme,NoBlocking}, ll,
                       verbose=false, it=NaN, uidx=NaN
                       ) where {ObsScheme <: AbstractObsScheme,UpdtIdx,ST}
    WW, Pᵒ, P, XXᵒ, XX, fpt = ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX, ws.fpt
    m = length(P)
    ϑ = conjugate_draw(θ, XX, P[1].Target, pu.priors[1], UpdtIdx())   # sample new parameter
    θᵒ = move_to_proper_place(ϑ, θ, UpdtIdx())     # align so that dimensions agree

    update_laws!(P, θᵒ)
    pu.recompute_ODEs && solve_back_rec!(NoBlocking(), P, ST()) # compute (H, Hν, c)

    for i in 1:m    # compute wiener path WW that generates XX
        inv_solve!(Euler(), XX[i], WW[i], P[i])
    end
    # compute white noise that generates starting point
    y = XX[1].yy[1]
    z = inv_start_pt(y, ws.x0_prior, P[1])

    llᵒ = logpdf(ws.x0_prior, y)
    llᵒ += path_log_likhd(ObsScheme(), XX, P, 1:m, fpt; skipFPT=true)
    llᵒ += lobslikelihood(P[1], y)
    print_info(verbose, it, value(ll), value(llᵒ))
    set!(ws.z, z)
    return llᵒ, true, θᵒ
end


"""
    update_param!(pu::ParamUpdtDefn{ConjugateUpdt,UpdtIdx,ST}, θ,
                  ws::Workspace{ObsScheme}, ll, verbose=false, it=NaN, uidx=NaN
                  ) -> accepted_log_likhd, accept_decision, accepted_parameter
Update parameters
see the definition of  update_param!(…, ::MetropolisHastingsUpdt, …) for the
explanation of the arguments.
"""
function update_param!(pu::ParamUpdtDefn{ConjugateUpdt,UpdtIdx,ST},
                       θ, ws::Workspace{ObsScheme},
                       ll, verbose=false, it=NaN, uidx=NaN
                       ) where {ObsScheme <: AbstractObsScheme, UpdtIdx, ST}
    WW, Pᵒ, P, XXᵒ, XX, fpt = ws.WW, ws.Pᵒ, ws.P, ws.XXᵒ, ws.XX, ws.fpt
    𝔅 = ws.blocking
    m = length(P)
    ϑ = conjugate_draw(θ, XX, P[1].Target, pu.priors[1], UpdtIdx())   # sample new parameter
    θᵒ = move_to_proper_place(ϑ, θ, UpdtIdx())     # align so that dimensions agree

    update_laws!(P, θᵒ, ws)
    pu.recompute_ODEs && solve_back_rec!(ws, P, ST())
    for i in 1:m    # compute wiener path WW that generates XX
        inv_solve!(Euler(), XX[i], WW[i], P[i])
    end
    # compute white noise that generates starting point
    y = XX[1].yy[1]
    z = inv_start_pt(y, ws.x0_prior, P[1])
    llᵒ = logpdf(ws.x0_prior, y)
    for block in 𝔅.blocks[ws.blidx]
        llᵒ += path_log_likhd(ObsScheme(), XX, P, block, ws.fpt; skipFPT=true)
        llᵒ += lobslikelihood(P[block[1]], XX[block[1]].yy[1])
    end
    print_info(verbose, it, value(ll), value(llᵒ))
    set!(ws.z, z)
    return llᵒ, true, θᵒ
end


"""
    mcmc(::ObsScheme, setup)

Gibbs sampler alternately imputing unobserved parts of the path and updating
unknown coordinates of the parameter vector (the latter only if paramUpdt==true)
...
# Arguments
- `::ObsScheme`: observation scheme---first-passage time or partial observations
- `setup`: variables that define the markov chain
...
"""
function mcmc(setup)
    adaptive_prop, num_mcmc_steps = setup.adaptive_prop, setup.num_mcmc_steps
    ws, ll, yPr, θ = Workspace(setup)
    gibbs = GibbsDefn(setup)
    init_adaptation!(adaptive_prop, ws)

    for i in 1:num_mcmc_steps
        verbose = act(Verbose(), ws, i)
        act(SavePath(), ws, i) && save_path!(ws)
        ws = next_set_of_blocks(ws)
        ll, acc = impute!(ws, ll, verbose, i)
        update!(ws.accpt_tracker, Imputation(), acc)

        if act(ParamUpdate(), ws, i)
            for j in 1:length(gibbs)
                ll, acc, θ = update_param!(gibbs[j], θ, ws, ll, verbose, i, j)
                update!(ws.accpt_tracker, ParamUpdate(), j, acc)
                update!(ws.θ_chain, θ)
                verbose && print("\n")
            end
            verbose && print("------------------------------------------------",
                             "------\n")
        end
        add_path!(adaptive_prop, ws.XX, i)
        #print_adaptation_info(adaptive_prop, accImpCounter, accUpdtCounter, i)
        adaptive_prop, ws, ll = update!(adaptive_prop, ws, i, ll)
        adaptive_prop = still_adapting(adaptive_prop)
    end
    display_acceptance_rate(ws.blocking)
    ws
end
