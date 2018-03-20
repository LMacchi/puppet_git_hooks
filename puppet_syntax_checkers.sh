#!/bin/bash

USER=`whoami`

# Puppet attempts to source ~/.puppet and will error if $HOME is not set
# In a gitlab install, git doesn't have permissions to write in its home
# dir, so we can workaround this by creating ~git/.puppetlabs, owned by
# the git user
if [ -z $HOME ]
then
  export HOME=$(grep "${USER}:" /etc/passwd | awk -F ':' '{print $6}')
fi

failures=0
RC=0

hook_dir="$(dirname $0)"
hook_symlink="$(readlink -f $0)"

# Figure out where commit hooks are if pre-receive is setup as a symlink
if [ ! -z "$hook_symlink" ]; then
  subhook_root="$(dirname $hook_symlink)/commit_hooks"
else
  subhook_root="$hook_dir/commit_hooks"
fi

tmptree=$(mktemp -d)

# Prevent tput from throwing an error by ensuring that $TERM is always set
if [ -z "$TERM" ]; then
  TERM=dumb
fi
export TERM

# Decide if we want puppet-lint
CHECK_PUPPET_LINT="enabled"
if [ -e ${subhook_root}/config.cfg ] ; then
  source ${subhook_root}/config.cfg
fi

while read oldrev newrev refname; do
  git archive $newrev | tar x -C ${tmptree}

	# for a new branch oldrev is 0{40}, set newrev to branch name and oldrev to parent branch
	if [[ $oldrev == "0000000000000000000000000000000000000000" ]]; then
	  newrev=`git rev-parse --abbrev-ref HEAD`
		oldrev=`git show-branch | grep '\*' | grep -v "$newrev" | head -n1 | sed 's/.*\[\(.*\)\].*/\1/' | sed 's/[\^~].*//'`
	fi

  for changedfile in $(git diff --name-only $oldrev $newrev --diff-filter=ACM); do
    tmpmodule="$tmptree/$changedfile"
    #check puppet manifest syntax
    if type puppet >/dev/null 2>&1; then
      if [ $(echo $changedfile | grep -q '\.*.pp$'; echo $?) -eq 0 ]; then
        ${subhook_root}/puppet_manifest_syntax_check.sh $tmpmodule "${tmptree}/"
        RC=$?
        if [ "$RC" -ne 0 ]; then
          failures=`expr $failures + 1`
        fi
      fi
    else
      echo "puppet not installed. Skipping puppet syntax checks..."
    fi

    if type ruby >/dev/null 2>&1; then
      #check erb (template file) syntax
      if type erb >/dev/null 2>&1; then
        if [ $(echo $changedfile | grep -q '\.*.erb$'; echo $?) -eq 0 ]; then
          ${subhook_root}/erb_template_syntax_check.sh $tmpmodule "${tmptree}/"
          RC=$?
          if [ "$RC" -ne 0 ]; then
            failures=`expr $failures + 1`
          fi
        fi
      else
        echo "erb not installed. Skipping erb template checks..."
      fi

      #check hiera data (yaml/yml) syntax
      if [ $(echo $changedfile | grep -q '\.*.yaml$\|\.*.yml$'; echo $?) -eq 0 ]; then 
        ${subhook_root}/yaml_syntax_check.sh $tmpmodule "${tmptree}/"
        RC=$?
        if [ "$RC" -ne 0 ]; then
          failures=`expr $failures + 1`
        fi
      fi
           
      #check hiera data (json) syntax
      if [ $(echo $changedfile | grep -q '\.*.json$'; echo $?) -eq 0 ]; then 
        ${subhook_root}/json_syntax_check.sh $tmpmodule "${tmptree}/"
        RC=$?
        if [ "$RC" -ne 0 ]; then
          failures=`expr $failures + 1`
        fi
      fi
    else
      echo "ruby not installed. Skipping erb/yaml checks..."
    fi

    #puppet manifest styleguide compliance
    if [ "$CHECK_PUPPET_LINT" != "disabled" ] ; then
      if type puppet-lint >/dev/null 2>&1; then
        if [ $(echo $changedfile | grep -q '\.*.pp$' ; echo $?) -eq 0 ]; then
          ${subhook_root}/puppet_lint_checks.sh $CHECK_PUPPET_LINT $tmpmodule "${tmptree}/"
          RC=$?
          if [ "$RC" -ne 0 ]; then
            failures=`expr $failures + 1`
          fi
        fi
      else
        echo "puppet-lint not installed. Skipping puppet-lint tests..."
      fi
    fi
  done
done
rm -rf ${tmptree}

#summary
if [ "$failures" -ne 0 ]; then
  echo -e "$(tput setaf 1)Error: $failures subhooks failed. Declining push.$(tput sgr0)"
  exit 1
fi

exit 0