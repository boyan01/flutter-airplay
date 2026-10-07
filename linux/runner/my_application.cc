#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "receiver_host.h"
#include "window_channel.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  ReceiverHost* receiver;
  WindowChannel* window_channel;
  bool launch_at_login;
  bool reopen_requested;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    // Preserve an activation even if Flutter is still constructing its view.
    if (self->window_channel) self->window_channel->Show();
    else self->reopen_requested = true;
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  gtk_window_set_title(window, "Flutter AirPlay");
  // Load the bundled icon independently of the current working directory.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* directory = executable ? g_path_get_dirname(executable) : nullptr;
  g_autofree gchar* icon = directory ? g_build_filename(
      directory, "data", "icons", "tech.soit.flutterairplay.png", nullptr) : nullptr;
  g_autoptr(GError) icon_error = nullptr;
  if (icon && !gtk_window_set_icon_from_file(window, icon, &icon_error)) {
    g_warning("Failed to load application icon: %s", icon_error->message);
  }
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_default_size(window, 440, 560);
  GdkGeometry geometry{};
  geometry.min_width = 360; geometry.min_height = 480;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // nativeapi window calls must execute on GTK's platform thread.
  fl_dart_project_set_ui_thread_policy(project, FL_UI_THREAD_POLICY_RUN_ON_PLATFORM_THREAD);
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  FlEngine* engine = fl_view_get_engine(view);
  self->window_channel = new WindowChannel(fl_engine_get_binary_messenger(engine),
                                           window, self->launch_at_login);
  self->receiver = new ReceiverHost(fl_engine_get_binary_messenger(engine),
                                   fl_engine_get_texture_registrar(engine),
                                   [](FlValue*) {});
  g_signal_connect_swapped(window, "delete-event", G_CALLBACK(+[](MyApplication* app) -> gboolean {
    if (app->window_channel->HideOnClose()) return TRUE;
    delete app->window_channel;
    app->window_channel = nullptr;
    delete app->receiver;
    app->receiver = nullptr;
    return FALSE;
  }), self);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  GtkWidget* overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  AddWindowResizeHandles(GTK_OVERLAY(overlay), window);
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(window), overlay);

  // Start Flutter without mapping the top-level window. Dart completes startup
  // after creating the tray; WindowChannel provides a timed visible fallback.
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
  if (self->reopen_requested) self->window_channel->Show();
}

// Implements GApplication::command_line in the primary process. GApplication
// forwards arguments from secondary invocations, preserving their launch source.
static int my_application_command_line(GApplication* application,
                                      GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  g_auto(GStrv) arguments = g_application_command_line_get_arguments(command_line, nullptr);
  g_autoptr(GPtrArray) dart_arguments = g_ptr_array_new_with_free_func(g_free);
  bool launch_at_login = false;
  for (gchar** argument = arguments + 1; *argument; ++argument) {
    if (!std::strcmp(*argument, "--launch-at-login")) launch_at_login = true;
    else g_ptr_array_add(dart_arguments, g_strdup(*argument));
  }
  if (gtk_application_get_windows(GTK_APPLICATION(application))) {
    // A delayed or repeated login invocation must not focus an existing app.
    if (launch_at_login) return 0;
  } else {
    self->launch_at_login = launch_at_login;
    g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
    g_ptr_array_add(dart_arguments, nullptr);
    self->dart_entrypoint_arguments =
        reinterpret_cast<gchar**>(g_ptr_array_free(g_steal_pointer(&dart_arguments), FALSE));
  }
  g_application_activate(application);
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  delete self->window_channel;
  self->window_channel = nullptr;
  delete self->receiver;
  self->receiver = nullptr;
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
