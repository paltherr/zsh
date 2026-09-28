#!/bin/zsh -f

emulate zsh

# Run all specified tests, keeping count of which succeeded.
# The reason for this extra layer above the test script is to
# protect from catastrophic failure of an individual test.
# We could probably do that with subshells instead.

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

typeset -a passing=() skipped=() failing=()

add-test-result() {
  case $1 in
    0) passing+=$test;;
    2) skipped+=$test;;
    *) failing+=$test;;
  esac
}

run-tests-sequentially() {
  local test
  for test in $tests; do
    run-test
    add-test-result $?
  done
}

run-tests-in-parallel() {
  # Setup data directory.
  local datadir=$0:h/rundata.tmp
  [[ -d $datadir ]] || mkdir $datadir

  # Setup logging, if requested.
  if (( ZTST_log )); then
    typeset -F SECONDS
    rm -f $datadir/runtests.log
    local -i log_fd && exec {log_fd}>$datadir/runtests.log
    local -a log=(print -u$log_fd -f "%8.3f %s\n" SECONDS)
  fi
  ((log_fd)) && $log "--- <<<"

  # Read run times from previous runs, if any.
  local -A test2real=() test2cpu=()
  [[ -r $datadir/runtimes.zsh ]] && . $datadir/runtimes.zsh

  # Sort tests by increasing real run time and then in reverse listing
  # order. Note that tests are run starting from the end of the array,
  # so slowest first and in listing order if no run time is available.
  local -i ntests=$#tests i
  for ((i=ntests; i; i--)); do
    tests[i]=$(( 1000 * test2real[$tests[i]] + ntests - i))-$tests[i]
  done
  tests=(${${(on)tests}#*-})

  # Setup FIFO for run results.
  rm -f $datadir/runresults.fifo
  mkfifo $datadir/runresults.fifo
  typeset -i fifo_fd && exec {fifo_fd}<>$datadir/runresults.fifo

  # Start up to ZTST_jobs jobs. Each job runs a single test, records
  # the output to a dedicated file, and writes the run result to the
  # result FIFO. Once jobs are started, wait for results in the result
  # FIFO, print the output and record the result, and restart new jobs
  # until there are no more tests left to run.
  local job test match mbegin mend
  local -i jobs=0 next=$#tests result real
  local -a output
  while (( jobs || next )); do
    if (( jobs < ZTST_jobs && next )); then
      # Start a new job
      printf -v job "%03d" $(( ++jobs ))
    else
      # Read one test result
      read -u$fifo_fd job test result
      ((log_fd)) && $log "$job >>> $test"
      output=( "${(@f)$(<$datadir/output-$job.log)}" )
      print -rl "${(@)output[1,-3]}"
      add-test-result $result
      if [[ $output[-1] =~ "children  ([0-9.]+)s user ([0-9.]+)s sys.* ([0-9.]+) tot" ]]; then
        real=$(( 1000 * match[3] ))
        # Save run times only if the test was successful or slower than previously
        if (( !result || real > test2real[$test] )); then
          test2real[$test]=$real
          test2cpu[$test]=$(( 1000 * (match[1] + match[2]) ))
        fi
      fi
      # End job and revive it if a next test is still there
      (( jobs-- && next && ++jobs )) || continue
    fi
    # Start next test
    test=$tests[next--]
    ((log_fd)) && $log "$job <<< $test"
    { &>$datadir/output-$job.log time run-test; print -u$fifo_fd $job $test $? } &
  done

  # Wait for all jobs to finish and close the run result FIFO.
  wait
  exec {fifo_fd}>&-
  rm -f $datadir/runresults.fifo

  # Save run times.
  typeset -p 1 test2cpu test2real >$datadir/runtimes.zsh

  # End logging.
  ((log_fd)) && $log "--- >>>"
  ((log_fd)) && exec {log_fd}>&-

  # Order test scripts alphabetically.
  passing=(${(o)passing})
  skipped=(${(o)skipped})
  failing=(${(o)failing})

  # Write run time data, if requested.
  if (( ZTST_log )); then
    local -i ntests=$#tests i
    for ((i=ntests; i; i--)); do
      tests[i]=$(( 1000 * 1000 * test2real[$tests[i]] + test2cpu[$tests[i]] ))-$tests[i]
    done
    tests=(${${(on)tests}#*-})
    printf "%9s %9s %9s   %s\n" \
        "Real time" "CPU time" "Idle part" "Test script" >$datadir/runtimes.txt
    for ((i=ntests; i; i--)); do
      local test=$tests[i]
      local -F real=$test2real[$test] cpu=$test2cpu[$test]
      printf "%9.3f %9.3f %8.2f%%   %s\n" \
          "real/1000" "cpu/1000" "100*(1-cpu/real)" "$test"
    done >>$datadir/runtimes.txt
  fi
}

typeset -a tests=(${${(f)ZTST_testlist}#./})
if (( ZTST_jobs )); then
  run-tests-in-parallel
else
  run-tests-sequentially
fi

typeset -a res=(
  "$#passing successful test script${${${#passing}:#1}:+s}"
  "$#failing failure${${${#failing}:#1}:+s}"
  "$#skipped skipped"
)
typeset resln=${(j<, >)res}
typeset rule=${resln//?/\*}
typeset col
[[ -n $ZTST_failcolor ]] &&
if (( $#failing )); then
  col=$ZTST_failcolor
elif (( $#passing )); then
  col=$ZTST_passcolor
else
  col=$ZTST_warncolor
fi

(( $#col )) && print -rnP - "%F{$col}"
print -rl - $rule $resln
(( !ZTST_hide_failing && $#failing )) &&
print -rl - '' "failing test script${${${#failing}:#1}:+s}:" ${(@)failing/#/  }
(( ZTST_show_skipped && $#skipped )) &&
print -rl - '' "skipped test script${${${#skipped}:#1}:+s}:" ${(@)skipped/#/  }
(( ZTST_show_passing && $#passing )) &&
print -rl - '' "passing test script${${${#passing}:#1}:+s}:" ${(@)passing/#/  }
print -rl - $rule
(( $#col )) && print -rnP - %f

return $(( $#failing ? 1 : 0 ))
