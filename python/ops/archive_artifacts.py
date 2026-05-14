#!/usr/bin/env python3
"""Archive logs/reports into compressed tar files and prune old archives."""

import argparse
import datetime
import os
import tarfile
import time


def _collect_files(path, older_than_days):
    if not os.path.isdir(path):
        return []
    now = time.time()
    min_age = older_than_days * 86400
    files = []
    for name in os.listdir(path):
        full = os.path.join(path, name)
        if not os.path.isfile(full):
            continue
        if now - os.path.getmtime(full) >= min_age:
            files.append(full)
    return sorted(files)


def _archive_group(files, archive_path, base_dir):
    if not files:
        return 0
    os.makedirs(os.path.dirname(archive_path), exist_ok=True)
    with tarfile.open(archive_path, "w:gz") as tar:
        for file_path in files:
            rel = os.path.relpath(file_path, base_dir)
            tar.add(file_path, arcname=rel)
    return len(files)


def _prune_archives(archive_dir, keep_days):
    if keep_days <= 0 or not os.path.isdir(archive_dir):
        return 0
    now = time.time()
    max_age = keep_days * 86400
    removed = 0
    for name in os.listdir(archive_dir):
        if not name.endswith(".tar.gz"):
            continue
        full = os.path.join(archive_dir, name)
        if os.path.isfile(full) and (now - os.path.getmtime(full)) > max_age:
            os.remove(full)
            removed += 1
    return removed


def main():
    parser = argparse.ArgumentParser(description="Archive ConnectivityMonitor logs/reports")
    parser.add_argument("--base-dir", default=os.path.expanduser("~/ConnectivityMonitor"))
    parser.add_argument("--older-than-days", type=int, default=1)
    parser.add_argument("--delete-after-archive", action="store_true")
    parser.add_argument("--keep-archive-days", type=int, default=30)
    args = parser.parse_args()

    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%SZ")
    logs_dir = os.path.join(args.base_dir, "logs")
    reports_dir = os.path.join(args.base_dir, "reports")
    archive_dir = os.path.join(args.base_dir, "archive")

    logs_files = _collect_files(logs_dir, args.older_than_days)
    reports_files = _collect_files(reports_dir, args.older_than_days)

    logs_archive = os.path.join(archive_dir, "logs_{}.tar.gz".format(ts))
    reports_archive = os.path.join(archive_dir, "reports_{}.tar.gz".format(ts))

    logs_count = _archive_group(logs_files, logs_archive, args.base_dir)
    reports_count = _archive_group(reports_files, reports_archive, args.base_dir)

    delete_errors = []
    if args.delete_after_archive:
        for file_path in logs_files + reports_files:
            try:
                os.remove(file_path)
            except OSError as exc:
                delete_errors.append("{} ({})".format(file_path, exc))

    pruned = _prune_archives(archive_dir, args.keep_archive_days)

    print(
        "Archived logs={}, reports={}, deleted_source={}, pruned_archives={}, delete_errors={}".format(
            logs_count,
            reports_count,
            bool(args.delete_after_archive),
            pruned,
            len(delete_errors),
        )
    )
    if delete_errors:
        for err in delete_errors:
            print("Delete error: {}".format(err))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
