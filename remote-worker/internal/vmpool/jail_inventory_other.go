//go:build !unix

package vmpool

import "io/fs"

// statLinksAndBlocks has no portable answer off unix. The package builds for windows
// (cgroup_windows.go) so that a developer there can compile and run the non-launcher
// tests, and the Firecracker launcher never runs on it -- so reporting one link and no
// blocks keeps the inventory honest about knowing nothing rather than inventing a count.
func statLinksAndBlocks(fs.FileInfo) (uint64, int64) { return 1, 0 }
