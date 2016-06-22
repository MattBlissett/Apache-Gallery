<div id="page">
	<div id="menu">{ $MENU }</div>

	<div id="directory">
		<div id="picture">
			<video rel="foaf:primaryTopicOf" poster="{ $POSTER }" controls>
				{ $SRCS }
				<p>Your browser doesn't support playing this video file directly. You could try <a href="{ $SRC }">downloading it</a>.</p>
				<a href="{ $SRC }"><img src="{ $POSTER }" alt="Video thumbnail"></a>
			</video>
			<div id="size-slideshow">
				<span id="slideshow">⌚ <span>{ $SLIDESHOW }</span></span>
			</div>
		</div>

		<div id="nav">
			<span class="nav left">{ $BACK }</span>
			<span class="nav right">{ $NEXT }</span>
		</div>

		<div class="clear"></div>

		<div class="info" about="{ $IMAGEURI }">
			<div id="pictureinfo-map">
				{ $PICTUREINFO }
				<div>{ $MAP }</div>
			</div>
		</div>
	</div>
</div>

{ $LICENSE }
