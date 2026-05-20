# bash completion for hither
_hither() {
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  local subcommands="bootstrap subscribe unsubscribe list sync status unmount remount logs doctor verify-no-leaks uninstall version help"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )
    return
  fi

  case "${COMP_WORDS[1]}" in
    bootstrap)
      COMPREPLY=( $(compgen -W "--reapply-only --user-only --root-only" -- "${cur}") )
      ;;
    subscribe)
      COMPREPLY=( $(compgen -W "--user --proto --schedule-hour --schedule-minute --notify --no-notify --notify=true --notify=false" -- "${cur}") )
      ;;
    unsubscribe|uninstall)
      COMPREPLY=( $(compgen -W "--purge" -- "${cur}") )
      ;;
    logs)
      COMPREPLY=( $(compgen -W "--tail" -- "${cur}") )
      ;;
    unmount|remount|sync)
      if [[ ${COMP_CWORD} -eq 2 ]]; then
        local subs=""
        if [[ -d "${HOME}/.config/hither/subscriptions" ]]; then
          subs="$(cd "${HOME}/.config/hither/subscriptions" && ls *.toml 2>/dev/null | sed 's/\.toml$//')"
        fi
        local extra=""
        [[ "${COMP_WORDS[1]}" != "sync" ]] && extra="all"
        COMPREPLY=( $(compgen -W "${subs} ${extra}" -- "${cur}") )
      elif [[ "${COMP_WORDS[1]}" == "sync" ]]; then
        COMPREPLY=( $(compgen -W "--notify --no-notify" -- "${cur}") )
      fi
      ;;
  esac
}
complete -F _hither hither
