# bash completion for hither
_hither() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "bootstrap doctor verify-no-leaks version help" -- "${cur}") )
  elif [[ "${prev}" == "bootstrap" ]]; then
    COMPREPLY=( $(compgen -W "--reapply-only" -- "${cur}") )
  fi
}
complete -F _hither hither
