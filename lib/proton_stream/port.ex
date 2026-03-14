# SPDX-FileCopyrightText: 2018 Frank Hunleth
# SPDX-FileCopyrightText: 2023 Ben Youngblood
# SPDX-FileCopyrightText: 2023 Jon Carstens
#
# SPDX-License-Identifier: Apache-2.0

defmodule ProtonStream.Port do
  @moduledoc false

  @spec muontrap_path() :: String.t()
  def muontrap_path() do
    Application.app_dir(:proton_stream, ["priv", "muontrap"])
  end
end
