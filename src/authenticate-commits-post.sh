#! /bin/bash

set -ex

# Set to true to post a comment to the issue.
case "${COMMENT:-true}" in
    0 | never | false | FALSE) COMMENT=never;;
    1 | always | true | TRUE) COMMENT=always;;
    on-error) COMMENT=on-error;;
    *)
        echo "Warning: Invalid value ('$COMMENT') for COMMENT." >&2;
        COMMENT=on-error
        ;;
esac

if test "x$GITHUB_EVENT_PATH" = x
then
    echo "GITHUB_EVENT_PATH environment variable must be set." >&2
    exit 1
fi

# All of the event properties are held under the github.event context,
# which is also available as JSON-encoded data in the file
# $GITHUB_EVENT_PATH.
#
# For an issue_comment event, see:
#
# https://docs.github.com/en/webhooks-and-events/webhooks/webhook-events-and-payloads#issue_comment

# Returns the value of the first key in the github.event data
# structure that is not null.
#
# Example:
#
#   $(github_event .issue.pull_request.url .pull_request.url)
#
# Returns github.event.issue.pull_request.url or, if that is not set,
# github.event.pull_request.url.  If neither is set, returns the empty
# string.
function github_event {
    while test $# -gt 0
    do
        VALUE=$(jq -r "$1" <$GITHUB_EVENT_PATH)
        if test "x$VALUE" != xnull
        then
            echo "$VALUE"
            break
        fi

        shift
    done
}


# authenticate-commits.sh saved the results to /github/home, which is
# exposed as "$RUNNER_TEMP/_github_home" here.
RESULTS=$RUNNER_TEMP/_github_home/authenticate-commits-results
if ! test -d "$RESULTS"
then
    echo "Results from authenticate-commits.sh ($RESULTS) not found."
    exit 1
fi

SQ_GIT_POLICY=$RESULTS/sq-git-policy-describe.json
SQ_GIT_POLICY_STDERR=$RESULTS/sq-git-policy-describe.err

SQ_GIT_LOG=$RESULTS/sq-git-log.json
SQ_GIT_LOG_STDERR=$RESULTS/sq-git-log.err
SQ_GIT_LOG_EXIT_CODE=$RESULTS/sq-git-log.ec

SQ_GIT_LOG_EXIT_CODE=$(cat $SQ_GIT_LOG_EXIT_CODE || printf 1)

# We don't want to displays the commits before the merge base.  We
# need to be careful though: if the merge base is a root (i.e., it has
# no parents), then $BASE_SHA^ is not a valid reference.
if test x$(git cat-file -t "$BASE_SHA^") = xcommit
then
    EXCLUDE="^$BASE_SHA^"
else
    EXCLUDE=
fi

COMMIT_GRAPH=$(mktemp)
git log --pretty=oneline --graph $EXCLUDE "$BASE_SHA" "$HEAD_SHA" \
    | tee -a "$COMMIT_GRAPH"

# Pretty-print the comment.
COMMENT_CONTENT=$(mktemp)
$(dirname $0)/format-comment.py --commit-graph "$COMMIT_GRAPH" \
             --log "$SQ_GIT_LOG" --trust-root "$BASE_SHA" \
             | tee -a "$COMMENT_CONTENT"

if test "$SQ_GIT_LOG_EXIT_CODE" != "0"
then
    {
        echo
        echo "*Failed to authenticate commits.*"
        echo
        if test -s "$SQ_GIT_LOG_STDERR"
        then
            echo
            echo '```text'
            cat "$SQ_GIT_LOG_STDERR"
            echo '```'
        fi
    } | tee -a "$COMMENT_CONTENT"
else
    {
        echo
        echo "The pull request's base ($BASE_SHA) authenticates the pull request's head ($HEAD_SHA)."
    } | tee -a "$COMMENT_CONTENT"
fi

# The step's summary.
{
    cat $COMMENT_CONTENT
    echo

    echo '```'
    echo "$ sq-git policy describe HEAD"
    cat "$SQ_GIT_POLICY"
    echo

    if test -s "$SQ_GIT_POLICY_STDERR"
    then
        echo "stderr:"
        cat "$SQ_GIT_POLICY_STDERR"
    fi
    echo '```'
} | tee -a $GITHUB_STEP_SUMMARY

# sed 's@[[]\([0-9A-F]\{16,40\}\)[]]@[\1](https://keyserver.ubuntu.com/pks/lookup?search=\1\&fingerprint=on\&op=index)@'

COMMENT_JSON=$(mktemp)
jq -n --rawfile log "$COMMENT_CONTENT" '{ "body": $log }' >"$COMMENT_JSON"

# Set the comment output variable.
{
    # https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#multiline-strings
    echo "comment<<EOF_COMMENT_JSON"
    cat "$COMMENT_JSON"
    echo "EOF_COMMENT_JSON"
} | tee -a "$GITHUB_OUTPUT"

if test "x$COMMENT" = xalways \
        -o \( "x$COMMENT" = xon-error -a "$SQ_GIT_LOG_EXIT_CODE" -ne 0 \)
then
    COMMENTS_URL="$(github_event .pull_request.comments_url)"
    curl --silent --show-error --location \
         -X POST \
         -H "Accept: application/vnd.github+json" \
         -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "X-GitHub-Api-Version: 2022-11-28" \
         $COMMENTS_URL \
         -d @$COMMENT_JSON
else
    echo "Not posting comment."
fi

exit $SQ_GIT_LOG_EXIT_CODE

