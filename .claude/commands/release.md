Guide me through releasing a new version. Ask for the version number, then:

1. Ensure the working tree is clean (`git status`)
2. Run `/build` to compile optimized binaries
3. Commit the updated binaries if changed
4. Create and push the git tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
5. Compute the SHA: `curl -fsSL https://github.com/rajulbabel/homebrew-claude/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
6. Update `Formula/permit.rb` with the new tag URL, sha256, and version
7. Commit and push the formula update
