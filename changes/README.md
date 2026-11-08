# Release notes, until a release gathers them

A pull request that changes something users will notice writes its release notes here, in a new file of its own named
after its branch and the UTC date and time it's made, such as `changes/edit-your-comments-20261108-021500.md`, rather
than in `CHANGELOG.md`, so that no two pull requests conflict over them. It says here too when it changes what a
source's description says, rather than raising its version. Never edit a file that's already on `main`: a later pull
request from the same branch writes a new one.

The next release gathers the notes into `CHANGELOG.md`, in the order their pull requests merged, raises the versions,
and deletes the files (`scripts/prepare-release.sh`). [Release notes](../CONTRIBUTING.md#release-notes), in
CONTRIBUTING.md, says what goes in a file.
