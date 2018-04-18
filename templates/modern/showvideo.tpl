<header id="menu">
	{ $MENU }
	<div id="menuButtons">
		<ul id="download"><li>&#10515;{ $ORIGINAL }</li></ul>
		<ul id="slideshow"><li>⌚ <ul>{ $SLIDESHOW }</ul></li></ul>
	</div>
</header>

<div id="directory">
	<div id="picture">
		<video rel="foaf:primaryTopicOf" poster="{ $POSTER }" controls>
			{ $SRCS }
			<p>Your browser doesn't support playing this video file directly. You could try <a href="{ $SRC }">downloading it</a>.</p>
			<a href="{ $SRC }"><img src="{ $POSTER }" alt="Video thumbnail"></a>
		</video>
	</div>

	<div id="nav">
		<span class="nav left">{ $BACK }</span>
		<span class="nav right">{ $NEXT }</span>
	</div>
</div>

<div class="info" about="{ $IMAGEURI }">
	<div id="pictureinfo-map">{ $PICTUREINFO }</div>

	{ $MAP }

	</div>
</div>

{ $LICENSE }

<script type="text/javascript">
	var hasInfo = true;
</script>
