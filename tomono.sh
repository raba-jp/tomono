#!/bin/bash

# Merge multiple repositories into one big monorepo. Migrates every branch in
# every subrepo to the eponymous branch in the monorepo, with all files
# (including in the history) rewritten to live under a subdirectory.
#
# To use a separate temporary directory while migrating, set the GIT_TMPDIR
# envvar.
#
# To access the individual functions instead of executing main, source this
# script from bash instead of executing it.

${DEBUGSH:+set -x}
if [[ "$BASH_SOURCE" == "$0" ]]; then
	is_script=true
	set -eu -o pipefail
else
	is_script=false
fi

# Default name of the mono repository (override with envvar)
: "${MONOREPO_NAME=core}"

# Monorepo directory
monorepo_dir="$PWD/$MONOREPO_NAME"



##### FUNCTIONS

# Silent pushd/popd
pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

function read_repositories {
	sed -e 's/#.*//' | grep .
}

# Simply list all files, recursively. No directories.
function ls-files-recursive {
	find . -type f | sed -e 's!..!!'
}

# List all branches for a given remote
function remote-branches {
	# With GNU find, this could have been:
	#
	#   find "$dir/.git/yada/yada" -type f -printf '%P\n'
	#
	# but it's not a real shell script if it's not compatible with a 14th
	# century OS from planet zorploid borploid.

	# Get into that git plumbing.  Cleanest way to list all branches without
	# text editing rigmarole (hard to find a safe escape character, as we've
	# noticed. People will put anything in branch names).
	pushd "$monorepo_dir/.git/refs/remotes/$1/"
	ls-files-recursive
	popd
}

function git-is-merged {
  merge_destination_branch=$1
  merge_source_branch=$2

  merge_base=$(git merge-base $merge_destination_branch $merge_source_branch)
  merge_source_current_commit=$(git rev-parse $merge_source_branch)


  if [[ $merge_base == $merge_source_current_commit ]]
  then
          echo "base and source are the same"
    return 0
  else
          echo "base and source are different"
    return 1
  fi
}

function should-merge-branch {
  branch_to_merge=$1
  remote=$2
  echo $branch_to_merge
  echo $name
        if [[ $branch_to_merge == *"feature"* ]]
        then
                if git-is-merged "$remote/develop" $branch_to_merge
                then
                        echo "feature merged don't need to merge to mono"
                        return 1
                else
                        return 0
                fi
        elif [[ $branch_to_merge == *"develop"* ]]
        then
                echo "develop"
                return 0
        elif [[ $branch_to_merge == *"master"* ]]
        then
                echo "master"
                return 0
				elif [[ $branch_to_merge == *"release"* ]]
        then
                echo "release"
                return 0
        else
                if git-is-merged "$remote/master" $branch_to_merge || git-is-merged "$remote/develop" $branch_to_merge
                then
                        echo "merged into master or develop don't merge"
                        echo $(git merge-base "$remote/develop" $branch_to_merge)
                        echo $(git merge-base "$remote/master" $branch_to_merge )
                        echo $(git rev-parse $branch_to_merge)
                        return 1
                else
                        echo "continue merge, it's not in master or develop branches"
                        return 0
                fi
        fi
}



# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function create-mono {
	# Pretty risky, check double-check!
	if [[ "${1:-}" == "--continue" ]]; then
		if [[ ! -d "$MONOREPO_NAME" ]]; then
			echo "--continue specified, but nothing to resume" >&2
			exit 1
		fi
		pushd "$MONOREPO_NAME"
	else
		if [[ -d "$MONOREPO_NAME" ]]; then
			echo "Target repository directory $MONOREPO_NAME already exists." >&2
			return 1
		fi
		mkdir "$MONOREPO_NAME"
		pushd "$MONOREPO_NAME"
		git init
	fi

	# This directory will contain all final tag refs (namespaced)
	mkdir -p .git/refs/namespaced-tags

	read_repositories | while read repo name folder; do

		if [[ -z "$name" ]]; then
			echo "pass REPOSITORY NAME pairs on stdin" >&2
			return 1
		elif [[ "$name" = */* ]]; then
			echo "Forward slash '/' not supported in repo names: $name" >&2
			return 1
		fi

                if [[ -z "$folder" ]]; then
			folder="$name"
                fi

		echo "Merging in $repo.." >&2
		git remote add "$name" "$repo"
		echo "Fetching $name.." >&2 
		git fetch -q "$name" --tags

		# # Now we've got all tags in .git/refs/tags: put them away for a sec
		# if [[ -n "$(ls .git/refs/tags)" ]]; then
		# 	mv .git/refs/tags ".git/refs/namespaced-tags/$name"
		# fi

		# Merge every branch from the sub repo into the mono repo, into a
		# branch of the same name (create one if it doesn't exist).
		remote-branches "$name" | while read branch; do
		  if should-merge-branch "$name/$branch" "$name"; then
				if git rev-parse -q --verify "$branch"; then
					# Branch already exists, just check it out (and clean up the working dir)
					git checkout -q "$branch"
					git checkout -q -- .
					git clean -f -d
				else
					# Create a fresh branch with an empty root commit"
					git checkout -q --orphan "$branch"
					# The ignore unmatch is necessary when this was a fresh repo
					git rm -rfq --ignore-unmatch .
					git commit -q --allow-empty -m "Root commit for $branch branch"
				fi
				git checkout -q $name/$branch
				git switch -q -c temp-munge-branch
				git filter-repo --force --path-rename :$name/ --refs temp-munge-branch
				git checkout -q $branch
				git reset -q --hard
				git merge -q --no-commit temp-munge-branch --allow-unrelated-histories
				git commit -q --no-verify --allow-empty -m "Merging $name to $branch"
				git checkout -q .
				git reset -q --hard
				git branch -D temp-munge-branch
			fi
		done

		git tag --list | while read tag
		do
				echo $tag
				if [[ $tag = */* ]]
				then
				echo "didn't update $tag"
				else
					echo "updated $tag to $name/$tag"
					git checkout -q $tag
					git checkout -q -- .
					git clean -f -d
					git switch -c temp-munge-branch
					git filter-repo --force --path-rename :$name/ --refs temp-munge-branch
					git tag $name/$tag $tag
					git tag -d $tag
					git checkout -q develop
					git branch -D temp-munge-branch
				fi
		done

	done

	# Restore all namespaced tags
	# rm -rf .git/refs/tags
	# mv .git/refs/namespaced-tags .git/refs/tags

	git checkout -q master
	git checkout -q .
}

if [[ "$is_script" == "true" ]]; then
	create-mono "${1:-}"
fi
