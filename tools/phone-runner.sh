#!/usr/bin/env bash
# phone-runner.sh v1.6 - lets Claude queue Verus benchmark jobs for this phone through a private GitHub repo.
#
# The phone polls the jobs repo (git over SSH with a deploy key that can only reach that one repo), runs
# each new job for this phone and commits the output back. A job can ONLY run one of the scripts in
# tools/ of the public fork (github.com/zzpajk/CCminer-ARM-optimized) at a pinned commit, with arguments
# from a fixed character set; nothing from the job file is ever evaluated as shell code.
#
#   bash phone-runner.sh setup NAME [DEVICE]   one-time: key, deploy-key check, clone, config, start
#        NAME = s8, s20, ... ; a second environment on the same phone (e.g. Termux next to UserLAnd) gets its
#        own NAME (s20-tx) and the same DEVICE (s20; default: NAME without a trailing -tx). Runners with the
#        same DEVICE never run jobs at the same time: a job first takes locks/DEVICE in the jobs repo.
#        Termux: the runner holds a wake lock; with the Termux:Boot app it also starts after a reboot.
#   bash phone-runner.sh start|stop|status|log
#
# Jobs repo layout (written by Claude):    jobs/NAME/<id>.job
#   script=bench | sweep | info | led | runner-update   (led: arg=cyan|magenta|...|off, tools/phone-led.sh)
#   commit=<fork commit, full 40-hex SHA> (not needed for info)
#   arg=<one argument per line>          e.g.  arg=-v   then   arg=baseline x2auto x2percore
#   timeout=<minutes>                    optional, default 240
# Results (written by the phone):         results/NAME/<id>/{status,console.log,report.txt}, results/NAME/heartbeat.txt
set -u
RUNNER_VERSION=1.6.1
JOBS_REPO="${VERUS_JOBS_REPO:-git@github.com:zzpajk/verus-phone-jobs.git}"
FORK="${VERUS_FORK:-https://github.com/zzpajk/CCminer-ARM-optimized.git}"
CONF="$HOME/.verus-runner.conf"
KEY="$HOME/.ssh/verus_jobs_key"
DIR="$HOME/verus-phone-jobs"
RUNS="$HOME/verus-runs"
SELF="$HOME/phone-runner.sh"
PIDF="$HOME/.verus-runner.pid"
LOGF="$HOME/verus-runner.log"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"

say() { echo "[$(date '+%F %T')] $*"; }
running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }

push_results() { # message
	( cd "$DIR" || exit 1
	  git add -A "results/$PHONE" >/dev/null 2>&1
	  git diff --cached --quiet && exit 0
	  git -c user.name="$PHONE" -c user.email="$PHONE@phones.invalid" commit -qm "$PHONE: $1" || exit 1
	  for i in 1 2 3 4 5; do
		git pull -q --rebase --autostash origin main >/dev/null 2>&1 || git rebase --abort >/dev/null 2>&1
		git push -q origin HEAD:main >/dev/null 2>&1 && exit 0
		sleep $((i * 5))
	  done; exit 1 ) || say "push failed ($1), will retry with the next push"
}

# ---- per-device lock in the jobs repo (environments of one phone cannot see each other's processes) ----
lock_file() { echo "$DIR/locks/$DEVICE"; }
lock_commit() { # message: commit + push only locks/DEVICE; 0 if pushed
	( cd "$DIR" || exit 1
	  git add -A "locks/$DEVICE" >/dev/null 2>&1
	  git diff --cached --quiet && exit 0
	  git -c user.name="$PHONE" -c user.email="$PHONE@phones.invalid" commit -qm "$PHONE: $1" || exit 1
	  git push -q origin HEAD:main >/dev/null 2>&1 && exit 0
	  git reset -q --hard HEAD~1 >/dev/null 2>&1; exit 1 )   # drop only this lock commit, then look again
}
lock_acquire() { # timeout-minutes
	local exp waited=0 owner until
	while :; do
		( cd "$DIR" && git pull -q --rebase --autostash origin main ) >/dev/null 2>&1 || git -C "$DIR" rebase --abort >/dev/null 2>&1
		if [ -f "$(lock_file)" ]; then
			read -r owner until < "$(lock_file)"
			if [ "$owner" != "$PHONE" ] && [ "${until:-0}" -gt "$(date +%s)" ] 2>/dev/null; then
				[ $waited = 0 ] && say "device $DEVICE busy ($owner until $(date -d @"$until" '+%T' 2>/dev/null || echo "$until")), waiting"
				waited=1; sleep 60; continue
			fi
		fi
		exp=$(( $(date +%s) + ($1 + 30) * 60 ))
		mkdir -p "$DIR/locks"; echo "$PHONE $exp" > "$(lock_file)"
		lock_commit "lock $DEVICE" && return 0
		sleep $((RANDOM % 20 + 5))   # someone else pushed first: look again
	done
}
lock_release() {
	local owner until
	( cd "$DIR" && git pull -q --rebase --autostash origin main ) >/dev/null 2>&1 || git -C "$DIR" rebase --abort >/dev/null 2>&1
	[ -f "$(lock_file)" ] || return 0
	read -r owner until < "$(lock_file)"
	[ "$owner" = "$PHONE" ] || return 0
	rm -f "$(lock_file)"
	for i in 1 2 3; do lock_commit "unlock $DEVICE" && return 0; ( cd "$DIR" && git pull -q --rebase origin main ) >/dev/null 2>&1; [ -f "$(lock_file)" ] || return 0; rm -f "$(lock_file)"; done
	say "could not release locks/$DEVICE (expires by itself)"
}

valid_arg() { case "$1" in *[!A-Za-z0-9\ ._,:=+/-]*) return 1;; esac; return 0; }

fetch_script() { # commit script-name -> path of a private copy
	mkdir -p "$RUNS"
	[ -d "$RUNS/fork.git" ] || git init -q --bare "$RUNS/fork.git"
	git -C "$RUNS/fork.git" fetch -q --depth 1 "$FORK" "$1" 2>/dev/null || git -C "$RUNS/fork.git" fetch -q "$FORK" variants 2>/dev/null
	local out="$RUNS/scripts/$1-$2"; mkdir -p "$RUNS/scripts"
	git -C "$RUNS/fork.git" show "$1:tools/$2" > "$out" 2>/dev/null || { rm -f "$out"; return 1; }
	echo "$out"
}

run_job() { # job-file
	local f=$1 id script="" commit="" tmo=240 args=() line k v rc=0
	id=$(basename "$f" .job)
	local R="$DIR/results/$PHONE/$id"; mkdir -p "$R"
	set -f
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}; case "$line" in ''|\#*) continue;; esac
		k=${line%%=*}; v=${line#*=}
		case "$k" in
		script) script=$v;; commit) commit=$v;; timeout) tmo=$v;;
		arg) valid_arg "$v" || { echo "failed $(date '+%F %T') bad argument: $v" > "$R/status"; set +f; push_results "job $id rejected"; return; }
		     args+=("$v");;
		*) echo "failed $(date '+%F %T') unknown key: $k" > "$R/status"; set +f; push_results "job $id rejected"; return;;
		esac
	done < "$f"
	set +f
	case "$tmo" in ''|*[!0-9]*) tmo=240;; esac
	case "$script" in bench|sweep|led|runner-update) case "$commit" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *)
		echo "failed $(date '+%F %T') bad commit: $commit" > "$R/status"; push_results "job $id rejected"; return;; esac;;
	info) ;; *) echo "failed $(date '+%F %T') unknown script: $script" > "$R/status"; push_results "job $id rejected"; return;; esac
	case "$commit" in *[!0-9a-f]*) echo "failed $(date '+%F %T') bad commit: $commit" > "$R/status"; push_results "job $id rejected"; return;; esac

	# never run on top of a benchmark someone started by hand
	while pgrep -f 'ccminer.*--benchmark' >/dev/null 2>&1; do say "a benchmark is already running, waiting"; sleep 60; done
	# and never at the same time as another environment of this phone (info jobs need no lock)
	[ "$script" != info ] && lock_acquire "$tmo"

	echo "running $(date '+%F %T') runner $RUNNER_VERSION" > "$R/status"
	push_results "job $id started"
	say "job $id: $script ${commit:+@$commit} ${args[*]:-}"
	local path="" W=""
	case "$script" in
	info)
		{ echo "runner $RUNNER_VERSION on $PHONE"; date; uname -a; . /etc/os-release 2>/dev/null; echo "os: ${PRETTY_NAME:-?}"
		  echo "clang: $(clang --version 2>/dev/null | head -1)"; echo "uptime: $(uptime)"
		  grep -m1 '^Features' /proc/cpuinfo; awk '/^processor/{p=$3} /^CPU implementer/{i=$4} /^CPU part/{print "  cpu" p ": " i ":" $4}' /proc/cpuinfo
		  for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "  ${c##*/} max=$(cat $c/cpufreq/cpuinfo_max_freq 2>/dev/null) cur=$(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"; done
		  echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)% $(cat /sys/class/power_supply/battery/status 2>/dev/null) temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
		  echo "free: $(free -m 2>/dev/null | awk 'NR==2{print $2" MB total, "$7" MB available"}')  disk: $(df -h "$HOME" | awk 'NR==2{print $4" free"}')"
		  pgrep -fa ccminer || echo "no ccminer running"
		} > "$R/console.log" 2>&1; rc=0;;
	led)
		path=$(fetch_script "$commit" phone-led.sh) && timeout 60 bash "$path" "${args[@]}" > "$R/console.log" 2>&1; rc=$?
		[ -n "$path" ] || { echo "could not fetch phone-led.sh at $commit" > "$R/console.log"; rc=1; };;
	runner-update)
		path=$(fetch_script "$commit" phone-runner.sh) && bash -n "$path" && cp "$path" "$SELF" && chmod +x "$SELF" \
			&& echo "updated to $(grep -m1 '^RUNNER_VERSION=' "$SELF")" > "$R/console.log" || { echo "update failed" > "$R/console.log"; rc=1; }
		echo "$([ $rc = 0 ] && echo done || echo failed) $(date '+%F %T') rc=$rc" > "$R/status"; push_results "job $id finished"
		lock_release
		[ $rc = 0 ] && { say "restarting with the new runner"; exec bash "$SELF" loop; }
		return;;
	bench|sweep)
		local sname=verus-ref-bench.sh; [ "$script" = sweep ] && sname=verus-core-sweep.sh
		path=$(fetch_script "$commit" "$sname") || { echo "failed $(date '+%F %T') could not fetch $sname at $commit" > "$R/status"; push_results "job $id failed"; return; }
		W="$RUNS/work-$script-${commit:0:7}"; mkdir -p "$W"
		# live progress: copy the console log into the repo every 5 minutes while the job runs
		# the live log lives outside the repo (git rewrites tracked files during pulls, which would detach the
		# job's open file from the repo copy); the runner copies it in for every progress push and at the end
		local LIVE="$W/console-$id.log"
		( VERUS_WORK="$W" VERUS_SWEEP_DIR="$W" timeout $((tmo * 60)) bash "$path" "${args[@]}" < /dev/null > "$LIVE" 2>&1; echo $? > "$W/.rc" ) &
		local jp=$! n=0
		while kill -0 $jp 2>/dev/null; do sleep 10; n=$((n + 1)); [ $((n % 30)) = 0 ] && { cp "$LIVE" "$R/console.log"; push_results "job $id progress"; }; done
		rc=$(cat "$W/.rc" 2>/dev/null || echo 1); rm -f "$W/.rc"
		# the scripts write through tee (process substitution), which can still be flushing when bash exits
		sleep 5
		cp "$LIVE" "$R/console.log"
		[ "$script" = bench ] && [ -f "$W/report.txt" ] && [ "$W/report.txt" -nt "$R/status" ] && cp "$W/report.txt" "$R/report.txt"
		# on failure keep the end of the build log and the memory state, so the cause is visible remotely
		if [ "$rc" != 0 ]; then
			{ echo "== rc=$rc"; echo "== tail of $W/build.log"; tail -60 "$W/build.log" 2>/dev/null
			  echo "== free -m"; free -m 2>/dev/null; echo "== dmesg (may be unreadable)"; dmesg 2>/dev/null | tail -15; } > "$R/failure.txt" 2>&1
		fi
		if [ "$script" = sweep ]; then
			local sl; sl=$(ls -t "$W"/sweep-*.txt 2>/dev/null | head -1)
			[ -n "$sl" ] && [ "$sl" -nt "$R/status" ] && cp "$sl" "$R/sweep-full.txt" && sed -n '/= RESULT/,$p' "$sl" > "$R/report.txt"
		fi;;
	esac
	echo "$([ "$rc" = 0 ] && echo done || echo failed) $(date '+%F %T') rc=$rc" > "$R/status"
	push_results "job $id finished rc=$rc"
	[ "$script" != info ] && lock_release
	say "job $id finished rc=$rc"
}

heartbeat() {
	mkdir -p "$DIR/results/$PHONE"
	{ echo "alive $(date '+%F %T') runner $RUNNER_VERSION"; echo "uptime: $(uptime)"
	  echo "battery: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)% $(cat /sys/class/power_supply/battery/status 2>/dev/null)"
	} > "$DIR/results/$PHONE/heartbeat.txt"
	push_results "heartbeat"
}

loop() {
	. "$CONF" || { echo "no $CONF, run setup first"; exit 1; }
	DEVICE=${DEVICE:-${PHONE%-tx}}
	echo $$ > "$PIDF"
	command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock   # Termux: keep the CPU awake
	git -C "$DIR" config user.name "$PHONE"; git -C "$DIR" config user.email "$PHONE@phones.invalid"
	say "runner $RUNNER_VERSION for $PHONE (device $DEVICE) started (pid $$)"
	lock_release   # a lock left by this runner before a crash or restart
	local last_hb=0 now
	while :; do
		( cd "$DIR" && git pull -q --rebase --autostash origin main ) >/dev/null 2>&1 || { say "pull failed (network?)"; git -C "$DIR" rebase --abort >/dev/null 2>&1; }
		for f in $(ls "$DIR/jobs/$PHONE"/*.job 2>/dev/null | sort); do
			[ -f "$DIR/results/$PHONE/$(basename "$f" .job)/status" ] && continue
			run_job "$f"; lock_release; last_hb=$(date +%s)   # release also after early failures (no-op if not held)
		done
		now=$(date +%s)
		[ $((now - last_hb)) -ge 1800 ] && { heartbeat; last_hb=$now; }
		sleep 60
	done
}

case "${1:-}" in
setup)
	PHONE=${2:-}; case "$PHONE" in ''|*[!a-z0-9-]*) echo "usage: bash phone-runner.sh setup NAME [DEVICE]   (lowercase letters/digits/-, e.g. s8 or s8-tx)"; exit 1;; esac
	DEVICE=${3:-${PHONE%-tx}}; case "$DEVICE" in ''|*[!a-z0-9-]*) echo "bad DEVICE: $DEVICE"; exit 1;; esac
	TERMUX=0; case "${PREFIX:-}" in *com.termux*) TERMUX=1;; esac
	if [ $TERMUX = 1 ]; then
		for c in git ssh ssh-keygen pgrep setsid; do command -v $c >/dev/null || {
			echo "installing tools (pkg install git openssh procps util-linux termux-tools)..."
			DEBIAN_FRONTEND=noninteractive pkg install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
				git openssh procps util-linux termux-tools || { echo "pkg install failed; run it by hand, then setup again"; exit 1; }
			break; }; done
	fi
	for c in git ssh ssh-keygen; do command -v $c >/dev/null || { echo "missing $c (sudo apt-get install git openssh-client, or in Termux: pkg install git openssh)"; exit 1; }; done
	[ "$(readlink -f "$0")" != "$(readlink -f "$SELF")" ] && cp "$0" "$SELF" && chmod +x "$SELF"
	mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
	[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "verus-jobs-$PHONE" -f "$KEY"
	echo; echo "Add this key to github.com/zzpajk/verus-phone-jobs -> Settings -> Deploy keys -> Add deploy key"
	echo "(title: $PHONE, tick 'Allow write access'):"; echo; cat "$KEY.pub"; echo
	until git ls-remote "$JOBS_REPO" >/dev/null 2>&1; do read -r -p "Press Enter once the key is added (Ctrl-C to stop)... " _ </dev/tty; done
	echo "Key works."
	[ -d "$DIR/.git" ] || git clone -q "$JOBS_REPO" "$DIR" || { echo "clone failed"; exit 1; }
	printf 'PHONE=%s\nDEVICE=%s\n' "$PHONE" "$DEVICE" > "$CONF"
	if [ $TERMUX = 1 ]; then
		mkdir -p "$HOME/.termux/boot"
		printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nbash %s start\n' "$SELF" > "$HOME/.termux/boot/verus-runner.sh"
		chmod +x "$HOME/.termux/boot/verus-runner.sh"
		echo "Termux: autostart script in ~/.termux/boot (needs the Termux:Boot app, opened once)."
	fi
	running && kill "$(cat "$PIDF")" 2>/dev/null
	nohup setsid bash "$SELF" loop >> "$LOGF" 2>&1 < /dev/null &
	sleep 2; running && echo "Runner started for $PHONE (log: $LOGF). It survives logging out of SSH; after a phone reboot run: bash $SELF start" \
		|| { echo "Runner did not start, see $LOGF"; exit 1; };;
start) running && { echo "already running (pid $(cat "$PIDF"))"; exit 0; }
	nohup setsid bash "$SELF" loop >> "$LOGF" 2>&1 < /dev/null & sleep 2; running && echo "started" || echo "failed, see $LOGF";;
stop) running && kill "$(cat "$PIDF")" && pkill -f 'verus-ref-bench.sh|verus-core-sweep.sh' ; rm -f "$PIDF"; echo "stopped";;
status) running && echo "running (pid $(cat "$PIDF"))" || echo "not running"; tail -5 "$LOGF" 2>/dev/null;;
log) tail -40 "$LOGF";;
loop) loop;;
*) sed -n '2,20p' "$0";;
esac
