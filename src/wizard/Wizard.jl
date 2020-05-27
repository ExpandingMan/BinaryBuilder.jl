# TODO make Wizard module

using REPL
using REPL.Terminals
using REPL.TerminalMenus
using ObjectFile.ELF
using HTTP
import PkgLicenses
using MbedTLS
using JLD2
using Pkg.BinaryPlatforms
using Dates

# It's Magic (TM)!
export run_wizard

include("state.jl")
include("github.jl")
include("yggdrasil.jl")
include("utils.jl")
include("obtain_source.jl")
include("interactive_build.jl")
include("deploy.jl")

function save_last_wizard_state(state::WizardState)
    create_and_bind_mutable_artifact!("wizard_state") do dir
        jldopen(joinpath(dir, "wizard.state"), "w") do f
            serialize(f, state)
        end
    end
    return state
end

function load_last_wizard_state(; as_is::Bool = false)
    wizard_state_dir = get_mutable_artifact_path("wizard_state")

    # If no state dir exists, early-exit
    if wizard_state_dir === nothing
        return WizardState()
    end

    try
        state = jldopen(joinpath(wizard_state_dir, "wizard.state"), "r") do f
            return unserialize(f)
        end

        if as_is
            # Return the state as it is, without further questions.
            return state
        end

        # Looks like we had an incomplete build; ask the user if they want to continue
        if !(state.step in (:done, :step1))
            terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
            choice = request(terminal,
                "Would you like to resume the previous incomplete wizard run?",
                RadioMenu([
                    "Resume previous run",
                    "Start from scratch",
                ]),
            )

            if choice == 1
                return state
            else
                return WizardState()
            end
        end
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end
        @error(e)
    end

    # Either something went wrong, or there was nothing interesting stored.
    # Either way, just return a blank slate.
    return WizardState()
end

function run_wizard(state::Union{Nothing,WizardState} = nothing)
    global last_wizard_state

    if state === nothing
        # If we weren't given a state, check to see if we'd like to resume a
        # previous run or start from scratch again.
        state = load_last_wizard_state()
    end

    try
        while state.step != :done
            if state.step == :step1
                step1(state)
                state.step = :step2
            elseif state.step == :step2
                step2(state)
                state.step = :step3
            elseif state.step == :step3
                step34(state)
            elseif state.step == :step3_retry
                step3_retry(state)
            elseif state.step == :step5a
                step5a(state)
            elseif state.step == :step5b
                step5b(state)
            elseif state.step == :step5c
                step5c(state)
                state.step = :step6
            elseif state.step == :step6
                step6(state)
            elseif state.step == :step7
                step7(state)
                state.step = :done
            end

            # Save it every step along the way
            save_last_wizard_state(state)
        end
    catch err
        # If anything goes wrong, immediately save the current wizard state
        save_last_wizard_state(state)
        if isa(err, InterruptException)
            msg = "\n\nWizard stopped, use BinaryBuilder.run_wizard() to resume"
            if state.step in (:step3, :step3_retry, :step5a, :step5b, :step5c, :step6)
                # We allow deploying a partial script only if the wizard got at
                # least to the interactive build and it isn't done.  `:step7`
                # would be about to deploy, no need to suggest using `deploy()`
                # at this stage.
                msg *= ",\nor BinaryBuilder.deploy() to deploy the incomplete script"
            end
            msg *= "\n\n"
            printstyled(state.outs, msg, bold=true, color=:red)
        else
            bt = catch_backtrace()
            Base.showerror(stderr, err, bt)
            println(state.outs, "\n")
        end
        return state
    end

    # We did it!
    save_last_wizard_state(state)

    println(state.outs, "\nWizard Complete. Press any key to exit...")
    read(state.ins, Char)

    state
end