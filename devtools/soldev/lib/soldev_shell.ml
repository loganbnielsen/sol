let read_file path = In_channel.with_open_text path In_channel.input_all

let run_cmd ?(echo = true) cmd =
  Sol_process.run_shell_rc ~echo cmd

let run_cmd_lines ?(echo = false) cmd =
  Sol_process.lines_shell ~echo cmd
