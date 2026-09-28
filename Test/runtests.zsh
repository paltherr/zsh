#!/bin/zsh -f

emulate zsh

# Run all specified tests, keeping count of which succeeded.
# The reason for this extra layer above the test script is to
# protect from catastrophic failure of an individual test.
# We could probably do that with subshells instead.

integer success=0 failure=0 skipped=0
typeset -a ffiles

# Colors to use for ztst messages. ZTST_failcolor is also used as a
# signal that colors are available generally.
if [[ -z $NO_COLOR && \
    ( -n $ZTST_failcolor || \
    ( -t 1 && \
    ( $TERM == *color* || "$( tput colors 2> /dev/null )" == <8-> ))) ]]; then
  : ${ZTST_failcolor:=red}
  : ${ZTST_warncolor:=yellow}
  : ${ZTST_passcolor:=green}
  typeset -x -m "ZTST_*color"
else
  unset -m "ZTST_*color"
fi

run-test() {
  $ZTST_exe +Z -f $ZTST_srcdir/ztst.zsh $test
  local -i result=$?
  (( result > 128 )) && {
    [[ -n $ZTST_failcolor ]] && print -rnP "%F{$ZTST_failcolor}"
    print -r - "$test: test failed: SIG$signals[result - 127]."
    [[ -n $ZTST_failcolor ]] && print -rnP %f
  }
  print
  return result
}

add-test-result() {
  case $1 in
    0) success+=1;;
    2) skipped+=1;;
    *) failure+=1 ffiles+=$test;;
  esac
}

run-tests-sequentially() {
  local test
  for test in $tests; do
    run-test
    add-test-result $?
  done
}

typeset -a tests=(${${(f)ZTST_testlist}#./})
run-tests-sequentially

typeset -a res=(
  "$success successful test script${${success:#1}:+s}"
  "$failure failure${${failure:#1}:+s}"
  "$skipped skipped"
)
typeset resln=${(j<, >)res}
typeset rule=${resln//?/\*}
typeset col
[[ -n $ZTST_failcolor ]] &&
if (( failure )); then
  col=$ZTST_failcolor
elif (( success )); then
  col=$ZTST_passcolor
else
  col=$ZTST_warncolor
fi

(( $#col )) && print -rnP - "%F{$col}"
print -rl - $rule $resln
(( $#ffiles )) &&
print -rl - '' "failing test script${${#ffiles:#1}:+s}:" ${(@)ffiles/#/  }
print -rl - $rule
(( $#col )) && print -rnP - %f

return $(( failure ? 1 : 0 ))
