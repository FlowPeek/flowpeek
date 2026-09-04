# frozen_string_literal: true

source "https://rubygems.org"

# Pinned deliberately. Scripts/generate_xcodeproj.rb relies on `predictabilize_uuids`, whose UUID
# derivation changed between 1.23 and 1.28: an unpinned gem regenerates every object identifier and
# the release workflow's drift check then rejects a project that is otherwise identical.
gem "xcodeproj", "1.28.1"
