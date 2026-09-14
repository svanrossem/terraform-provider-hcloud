package server_test

import (
	"context"
	"fmt"
	"slices"
	"testing"

	"github.com/hashicorp/terraform-plugin-testing/helper/resource"
	"github.com/hashicorp/terraform-plugin-testing/terraform"
	"github.com/hashicorp/terraform-plugin-testing/tfversion"
	"github.com/stretchr/testify/assert"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/server"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/sshkey"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/teste2e"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/testmux"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/testsupport"
	"github.com/hetznercloud/terraform-provider-hcloud/internal/testtemplate"
)

func TestAccServerActions(t *testing.T) {
	tmplMan := testtemplate.Manager{}

	s := &hcloud.Server{}

	sk := sshkey.NewRData(t, "server-actions")

	res := &server.RData{
		Name:         "server-actions",
		Type:         teste2e.TestServerType,
		Image:        teste2e.TestImage,
		LocationName: teste2e.TestLocationName,
		SSHKeys:      []string{sk.TFID() + ".id"},
	}
	res.SetRName("default")

	resActionPoweroff := &server.AData{
		Type:     "poweroff",
		ServerID: res.TFID() + ".id",
	}
	resActionPoweroff.SetRName("default")

	resActionPoweron := testtemplate.DeepCopy(t, resActionPoweroff)
	resActionPoweron.Type = "poweron"

	resActionReboot := testtemplate.DeepCopy(t, resActionPoweroff)
	resActionReboot.Type = "reboot"

	resActionReset := testtemplate.DeepCopy(t, resActionPoweroff)
	resActionReset.Type = "reset"

	res.Raw = fmt.Sprintf(`
		lifecycle {
			action_trigger {
				events  = [after_create]
				actions = [
					%s,
					%s,
					%s,
					%s
				]
			}
		}
	`, resActionPoweroff.TFID(), resActionPoweron.TFID(), resActionReboot.TFID(), resActionReset.TFID())

	resource.ParallelTest(t, resource.TestCase{
		// Actions are only available in 1.14 and later
		TerraformVersionChecks: []tfversion.TerraformVersionCheck{
			tfversion.SkipBelow(tfversion.Version1_14_0),
		},
		PreCheck:                 teste2e.PreCheck(t),
		ProtoV6ProviderFactories: testmux.ProtoV6ProviderFactories(),

		Steps: []resource.TestStep{
			{
				Config: tmplMan.Render(t,
					"testdata/r/hcloud_ssh_key", sk,
					"testdata/r/hcloud_server", res,
					"testdata/a/hcloud_server", resActionPoweroff,
					"testdata/a/hcloud_server", resActionPoweron,
					"testdata/a/hcloud_server", resActionReboot,
					"testdata/a/hcloud_server", resActionReset,
				),
				Check: resource.ComposeTestCheckFunc(
					testsupport.CheckAPIResourcePresent(res.TFID(), testsupport.CopyAPIResource(s, server.GetAPIResource())),
					func(_ *terraform.State) error {
						client, err := testsupport.CreateClient()
						if err != nil {
							return err
						}

						actions, err := client.Server.Action.AllFor(context.Background(), s, hcloud.ActionListOpts{})
						if err != nil {
							return err
						}

						actionWithCommand := func(command string) func(*hcloud.Action) bool {
							return func(action *hcloud.Action) bool {
								return action.Command == command
							}
						}

						assert.True(t, slices.ContainsFunc(actions, actionWithCommand("stop_server")))
						assert.True(t, slices.ContainsFunc(actions, actionWithCommand("start_server")))
						assert.True(t, slices.ContainsFunc(actions, actionWithCommand("reboot_server")))
						assert.True(t, slices.ContainsFunc(actions, actionWithCommand("reset_server")))

						return nil
					},
				),
			},
		},
	})
}

func checkServerActionCount(serverID int64, command string, wantAtLeast int) func(*terraform.State) error {
	return func(_ *terraform.State) error {
		client, err := testsupport.CreateClient()
		if err != nil {
			return err
		}

		server := &hcloud.Server{ID: serverID}
		actions, err := client.Server.Action.AllFor(context.Background(), server, hcloud.ActionListOpts{})
		if err != nil {
			return err
		}

		count := 0
		for _, action := range actions {
			if action.Command == command {
				count++
			}
		}

		if count < wantAtLeast {
			return fmt.Errorf("expected at least %d %s action(s) for server %d, got %d", wantAtLeast, command, serverID, count)
		}

		return nil
	}
}

func TestAccServerRebuildAction(t *testing.T) {
	tmplMan := testtemplate.Manager{}

	s := &hcloud.Server{}

	sk := sshkey.NewRData(t, "server-rebuild-action")

	res := &server.RData{
		Name:         "server-rebuild-action",
		Type:         teste2e.TestServerType,
		Image:        teste2e.TestImage,
		LocationName: teste2e.TestLocationName,
		SSHKeys:      []string{sk.TFID() + ".id"},
	}
	res.SetRName("default")

	resActionRebuild := &server.ARebuildData{
		ServerID: res.TFID() + ".id",
		Image:    teste2e.TestImage,
	}
	resActionRebuild.SetRName("default")

	resActionRebuildWithUserData := testtemplate.DeepCopy(t, resActionRebuild)
	resActionRebuildWithUserData.SetRName("with_user_data")
	resActionRebuildWithUserData.UserData = "#cloud-config"

	res.Raw = fmt.Sprintf(`
		lifecycle {
			action_trigger {
				events  = [after_create]
				actions = [
					%s
				]
			}
		}
	`, resActionRebuild.TFID())

	resource.ParallelTest(t, resource.TestCase{
		// Actions are only available in 1.14 and later
		TerraformVersionChecks: []tfversion.TerraformVersionCheck{
			tfversion.SkipBelow(tfversion.Version1_14_0),
		},
		PreCheck:                 teste2e.PreCheck(t),
		ProtoV6ProviderFactories: testmux.ProtoV6ProviderFactories(),

		Steps: []resource.TestStep{
			{
				Config: tmplMan.Render(t,
					"testdata/r/hcloud_ssh_key", sk,
					"testdata/r/hcloud_server", res,
					"testdata/a/hcloud_server_rebuild", resActionRebuild,
				),
				Check: resource.ComposeTestCheckFunc(
					testsupport.CheckAPIResourcePresent(res.TFID(), testsupport.CopyAPIResource(s, server.GetAPIResource())),
					func(state *terraform.State) error { return checkServerActionCount(s.ID, "rebuild_server", 1)(state) },
				),
			},
			{
				Config: tmplMan.Render(t,
					"testdata/r/hcloud_ssh_key", sk,
					"testdata/r/hcloud_server", res,
					"testdata/a/hcloud_server_rebuild", resActionRebuildWithUserData,
				),
				Check: resource.ComposeTestCheckFunc(
					testsupport.CheckAPIResourcePresent(res.TFID(), testsupport.CopyAPIResource(s, server.GetAPIResource())),
					func(state *terraform.State) error { return checkServerActionCount(s.ID, "rebuild_server", 2)(state) },
				),
			},
		},
	})
}
