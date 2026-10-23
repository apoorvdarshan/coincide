# Native pull request review workspace

Read [the shared contract](README.md) and [coordination instructions](../CLOUD_TASKS.md) first.

Assigned branch: `parallel/pr-review-20261024`.

Implement reachable bounded PR diff/comments/replies/review forms in the existing native PR detail flow. Own GitHubPullRequestReview* and native review/diff view/store files. Capture repository/head/base/review target at opening; refuse stale-head writes. Preserve unsent drafts on failure and use original durable command IDs and operation receipts for write recovery after lost replies, never automatic resend. Existing detail/status/merge controls must remain. Follow existing GitHub service command launch/cancellation/credentials behavior. Use offline peers to verify pagination/size bounds, exact head targeting, pending/accepted/unknown outcomes, drafts and cancellation. Do not implement PR watch/link ledger (another task), live-post comments/reviews, or use dummy success fixtures as runtime proof.
